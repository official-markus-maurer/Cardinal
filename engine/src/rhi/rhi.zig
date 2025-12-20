const std = @import("std");
const types = @import("rhi_types.zig");

// Export types
pub const Format = types.Format;
pub const BufferUsage = types.BufferUsage;
pub const TextureUsage = types.TextureUsage;
pub const MemoryUsage = types.MemoryUsage;
pub const ShaderStage = types.ShaderStage;

// Hardcoded backend for now
const backend = @import("vulkan/backend.zig");

pub const Device = backend.Device;
pub const Buffer = backend.Buffer;
pub const Texture = backend.Texture;
pub const CommandList = backend.CommandList;
