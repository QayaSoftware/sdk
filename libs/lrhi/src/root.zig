//! lrhi, a render hardware interface: a thin, explicit device layer that any
//! renderer can be built on. Everything that knows the graphics API is in the
//! directory of the backend chosen here, with `-Dlrhi_backend`.
//!
//! The binding model, which every backend keeps:
//! - One global table of textures and samplers, bound by every encoder
//!   (`CommandEncoder.bindGlobals`). Shaders index it with
//!   `Device.textureIndex`, `Device.samplerIndex`, `Device.storageIndex`
//!   and `Device.storageArrayIndex`; there are no per-draw descriptor sets.
//! - Buffers are reached by device address (`Device.bufferAddress`) and
//!   top-level structures by theirs (`Device.accelerationAddress`), passed
//!   in push constants or in other buffers.
//! - Push constants of up to `push_constant_size` bytes, shared by every
//!   stage, are the only per-draw and per-dispatch input.
//! - Instance buffers hold `PackedInstance`, the backend's own layout, from
//!   `Device.packInstance`.
//! On D3D12 this is a bindless descriptor heap and root constants; on Metal,
//! argument buffers with residency sets.
const types = @import("types.zig");

/// The graphics API this build is on.
pub const backend = @import("lrhi_options").backend;
const implementation = switch (backend) {
    .vulkan => struct {
        const device = @import("vulkan/device.zig");
        const command = @import("vulkan/command.zig");
        const native = @import("vulkan/native.zig");
    },
};
const device = implementation.device;

pub const Device = device.Device;
/// Most encoders `Device.beginParallel` gives at once.
pub const max_parallel = device.max_parallel;
pub const FrameGenerator = device.FrameGenerator;
/// Native handles of the backend, for external SDKs such as lrhi-dlss.
pub const native = implementation.native;
pub const Detached = device.Detached;
pub const Frame = device.Frame;
pub const CommandEncoder = implementation.command.CommandEncoder;
pub const frames_in_flight = device.frames_in_flight;
pub const push_constant_size = device.push_constant_size;

pub const Buffer = types.Buffer;
pub const Texture = types.Texture;
pub const Sampler = types.Sampler;
pub const Pipeline = types.Pipeline;
pub const DeviceDesc = types.DeviceDesc;
pub const Surface = types.Surface;
pub const NativeWindow = types.NativeWindow;
pub const Format = types.Format;
pub const TextureDesc = types.TextureDesc;
pub const TextureUsage = types.TextureUsage;
pub const TextureKind = types.TextureKind;
pub const TextureInfo = types.TextureInfo;
pub const TextureState = types.TextureState;
pub const BufferDesc = types.BufferDesc;
pub const BufferUsage = types.BufferUsage;
pub const BufferMemory = types.BufferMemory;
pub const BufferSync = types.BufferSync;
pub const BufferAccess = types.BufferAccess;
pub const SamplerDesc = types.SamplerDesc;
pub const Filter = types.Filter;
pub const AddressMode = types.AddressMode;
pub const CompareOp = types.CompareOp;
pub const GraphicsPipelineDesc = types.GraphicsPipelineDesc;
pub const ComputePipelineDesc = types.ComputePipelineDesc;
pub const ColorTarget = types.ColorTarget;
pub const DepthState = types.DepthState;
pub const BlendMode = types.BlendMode;
pub const CullMode = types.CullMode;
pub const Topology = types.Topology;
pub const VertexLayout = types.VertexLayout;
pub const VertexAttribute = types.VertexAttribute;
pub const VertexFormat = types.VertexFormat;
pub const RenderingDesc = types.RenderingDesc;
pub const ColorAttachment = types.ColorAttachment;
pub const DepthAttachment = types.DepthAttachment;
pub const LoadOp = types.LoadOp;
pub const IndexType = types.IndexType;
pub const Work = types.Work;
pub const PassTiming = types.PassTiming;
pub const MemoryStats = types.MemoryStats;
pub const AdapterInfo = types.AdapterInfo;
pub const Capabilities = types.Capabilities;
pub const BlasGeometry = types.BlasGeometry;
pub const BlasBuild = types.BlasBuild;
pub const TlasDesc = types.TlasDesc;
pub const BuildPreference = types.BuildPreference;
pub const max_blas_geometries = types.max_blas_geometries;
pub const FormatSupport = types.FormatSupport;
pub const AdapterKind = types.AdapterKind;
pub const AccelerationStructure = types.AccelerationStructure;
pub const OpacityMicromap = types.OpacityMicromap;
pub const OpacityMicromapDesc = types.OpacityMicromapDesc;
pub const Opacity = types.Opacity;
pub const OpacityStates = types.OpacityStates;
pub const BlasDesc = types.BlasDesc;
pub const InstanceDesc = types.InstanceDesc;
pub const InstanceFlags = types.InstanceFlags;
/// The backend's layout of an instance of a top-level structure, as
/// instance buffers hold it; see `Device.packInstance`.
pub const PackedInstance = implementation.device.PackedInstance;
