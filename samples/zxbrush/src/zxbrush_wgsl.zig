// zig fmt: off
const global =
\\  const gamma: f32 = 2.2;
\\  const pi: f32 = 3.1415926;
\\
\\  fn saturate(x: f32) -> f32 {
\\      return clamp(x, 0.0, 1.0);
\\  }
\\
;
const common =
\\  struct MeshUniforms {
\\      object_to_world: mat4x4<f32>,
\\      object_to_world_edge: mat4x4<f32>,
\\      object_to_world_sel: mat4x4<f32>,
\\      world_to_clip: mat4x4<f32>,
\\  }
\\
\\  @group(0) @binding(0) var<uniform> uniforms: MeshUniforms;
\\
;
pub const img_vs = common ++
\\  struct VertexOut {
\\      @builtin(position) position_clip: vec4<f32>,
\\      @location(0) position: vec3<f32>,
\\      @location(1) texcoord: vec2<f32>,
\\  }
\\
\\  @vertex fn main(
\\      @location(0) position: vec3<f32>,
\\      @location(1) texcoord: vec2<f32>,
\\  ) -> VertexOut {
\\      var output: VertexOut;
\\      output.position_clip = vec4(position, 1.0) * uniforms.object_to_world * uniforms.world_to_clip;
\\      output.position = (vec4(position, 1.0) * uniforms.object_to_world).xyz;
\\      output.texcoord = texcoord;
\\      return output;
\\  }
\\
;
pub const img_fs = global ++ common ++
\\  @group(0) @binding(1) var img_tex: texture_2d<f32>;
\\  @group(0) @binding(2) var samp: sampler;
\\
\\  @fragment fn main(
\\      @location(0) position: vec3<f32>,
\\      @location(1) texcoord: vec2<f32>,
\\  ) -> @location(0) vec4<f32> {
\\      let color = textureSample(img_tex, samp, texcoord);
\\      // use precompiled alpha notation
\\      return vec4(color.xyz * color.w, color.w);
\\  }
\\
;
pub const edge_vs = common ++
\\  struct VertexOut {
\\      @builtin(position) position_clip: vec4<f32>,
\\      @location(0) position: vec3<f32>,
\\  }
\\
\\  @vertex fn main(
\\      @location(0) position: vec3<f32>,
\\      @location(1) texcoord: vec2<f32>,
\\  ) -> VertexOut {
\\      var output: VertexOut;
\\      output.position_clip = vec4(position, 1.0) * uniforms.object_to_world_edge * uniforms.world_to_clip;
\\      output.position = (vec4(position, 1.0) * uniforms.object_to_world_edge).xyz;
\\      return output;
\\  }
\\
;
pub const edge_fs = global ++ common ++
\\  @fragment fn main(
\\      @location(0) position: vec3<f32>,
\\  ) -> @location(0) vec4<f32> {
\\      let color = vec4(1.0, 0.0, 0.0, 1.0);
\\      return color;
\\  }
\\
;
pub const sel_vs = common ++
\\  struct VertexOut {
\\      @builtin(position) position_clip: vec4<f32>,
\\      @location(0) position: vec3<f32>,
\\      @location(1) texcoord: vec2<f32>,
\\  }
\\
\\  @vertex fn main(
\\      @location(0) position: vec3<f32>,
\\      @location(1) texcoord: vec2<f32>,
\\  ) -> VertexOut {
\\      var output: VertexOut;
\\      output.position_clip = vec4(position, 1.0) * uniforms.object_to_world_sel * uniforms.world_to_clip;
\\      output.position = (vec4(position, 1.0) * uniforms.object_to_world_sel).xyz;
\\      output.texcoord = texcoord;
\\      return output;
\\  }
\\
;
pub const sel_fs = global ++ common ++
\\  @group(0) @binding(1) var img_tex: texture_2d<f32>;
\\  @group(0) @binding(2) var samp: sampler;
\\
\\  @fragment fn main(
\\      @location(0) position: vec3<f32>,
\\      @location(1) texcoord: vec2<f32>,
\\  ) -> @location(0) vec4<f32> {
\\      return vec4(0.5, 0.0, 0.0, 0.5);
\\      //return vec4(1, 1, 1, 1);
\\  }
\\
;
// zig fmt: on
