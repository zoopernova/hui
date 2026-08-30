//! Native-Wayland WSI shim for Impeller's Vulkan backend.
//!
//! Impeller's standalone SDK can't size its swapchain on native Wayland, so the
//! window renders into a ~1x1 surface scaled up (only the background shows). Root
//! cause, traced through the engine source:
//!   - The interop peer hardcodes the requested swapchain size to `ISize::MakeWH(1,1)`
//!     (`toolkit/interop/backend/vulkan/swapchain_vk.cc`).
//!   - The swapchain impl sets `imageExtent = clamp(requested, minImageExtent,
//!     maxImageExtent)` (`renderer/backend/vulkan/swapchain/khr/khr_swapchain_impl_vk.cc`).
//!   - On Wayland `currentExtent` is `{0xFFFFFFFF, 0xFFFFFFFF}` ("app chooses"), and
//!     the auto-resize path (`GetCurrentUnderlyingSurfaceSize`) returns null, so the
//!     1x1 is never corrected. There's no C API to pass a size (Impeller TODO 163070).
//!
//! Impeller resolves every Vulkan function through the proc-address callback we give
//! it. So we hand it OUR callback and wrap `vkGetPhysicalDeviceSurfaceCapabilities[2]KHR`
//! to pin BOTH `minImageExtent` and `currentExtent` to the live window size. Pinning
//! `minImageExtent` makes `clamp(1, size, max) == size`, so the swapchain is created
//! at the real size; the `currentExtent` pin keeps Impeller's resize path honest. The
//! actual `vkCreateSwapchainKHR` still gets a legal extent (within the real min/max).
//!
//! ponytail: one global shim — single window. Fine for now; thread the shim through
//! user_data into the wrappers if HUI ever drives >1 window.

const std = @import("std");

const c = @cImport({
    @cInclude("vulkan/vulkan_core.h");
});

pub const Extent = struct { width: u32, height: u32 };

/// Returns the window's current drawable size in pixels. `ctx` is opaque userdata.
pub const SizeCallback = *const fn (ctx: ?*anyopaque) Extent;

pub const Shim = struct {
    real_gipa: c.PFN_vkGetInstanceProcAddr,
    // Resolved lazily the first time Impeller asks for each caps function (we have the
    // instance then). Used by the wrappers, which have no instance of their own.
    real_get_caps: c.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR = null,
    real_get_caps2: c.PFN_vkGetPhysicalDeviceSurfaceCapabilities2KHR = null,
    size_cb: SizeCallback,
    size_ctx: ?*anyopaque,
};

// Single-window global (see file header). Set by `install`.
var g_shim: ?*Shim = null;

/// Point Impeller at this shim. `real_gipa` is the real `vkGetInstanceProcAddr`
/// (opaque); `size_cb`/`size_ctx` yield the live window size on demand.
pub fn install(shim: *Shim, real_gipa: ?*const anyopaque, size_cb: SizeCallback, size_ctx: ?*anyopaque) void {
    shim.* = .{
        .real_gipa = @ptrCast(real_gipa),
        .size_cb = size_cb,
        .size_ctx = size_ctx,
    };
    g_shim = shim;
}

/// The proc-address callback handed to Impeller. Matches
/// `ImpellerVulkanProcAddressCallback` (instance, name, user_data). Forwards
/// everything to the real loader except the two surface-capabilities queries.
pub fn procAddr(instance: ?*anyopaque, name: [*c]const u8, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const shim: *Shim = @ptrCast(@alignCast(user_data.?));
    const n = std.mem.span(name);
    if (std.mem.eql(u8, n, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")) {
        shim.real_get_caps = @ptrCast(shim.real_gipa.?(@ptrCast(instance), name));
        return @constCast(@ptrCast(&getSurfaceCapabilities));
    }
    if (std.mem.eql(u8, n, "vkGetPhysicalDeviceSurfaceCapabilities2KHR")) {
        shim.real_get_caps2 = @ptrCast(shim.real_gipa.?(@ptrCast(instance), name));
        return @constCast(@ptrCast(&getSurfaceCapabilities2));
    }
    return @constCast(@ptrCast(shim.real_gipa.?(@ptrCast(instance), name)));
}

fn getSurfaceCapabilities(
    physical_device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
    caps: [*c]c.VkSurfaceCapabilitiesKHR,
) callconv(.c) c.VkResult {
    const shim = g_shim.?;
    const result = shim.real_get_caps.?(physical_device, surface, caps);
    if (result != c.VK_SUCCESS) return result;
    pinExtent(&caps.*);
    return result;
}

fn getSurfaceCapabilities2(
    physical_device: c.VkPhysicalDevice,
    surface_info: [*c]const c.VkPhysicalDeviceSurfaceInfo2KHR,
    caps: [*c]c.VkSurfaceCapabilities2KHR,
) callconv(.c) c.VkResult {
    const shim = g_shim.?;
    const result = shim.real_get_caps2.?(physical_device, surface_info, caps);
    if (result != c.VK_SUCCESS) return result;
    pinExtent(&caps.*.surfaceCapabilities);
    return result;
}

/// Pin minImageExtent + currentExtent to the live window size (see file header).
fn pinExtent(caps: *c.VkSurfaceCapabilitiesKHR) void {
    const shim = g_shim.?;
    const raw = shim.size_cb(shim.size_ctx);
    const w = std.math.clamp(raw.width, 1, caps.maxImageExtent.width);
    const h = std.math.clamp(raw.height, 1, caps.maxImageExtent.height);
    caps.minImageExtent = .{ .width = w, .height = h };
    caps.currentExtent = .{ .width = w, .height = h };
}
