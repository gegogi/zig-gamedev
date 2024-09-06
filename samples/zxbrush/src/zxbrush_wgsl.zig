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
const img_common =
\\  struct MeshUniforms {
\\      object_to_world: mat4x4<f32>,
\\      world_to_clip: mat4x4<f32>,
\\  }
\\
\\  @group(0) @binding(0) var<uniform> uniforms: MeshUniforms;
\\
;
pub const img_vs = img_common ++
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
pub const img_fs = global ++ img_common ++
\\  @group(0) @binding(1) var img_tex: texture_2d<f32>;
\\
\\  @group(0) @binding(2) var samp: sampler;
\\
\\  @fragment fn main(
\\      @location(0) position: vec3<f32>,
\\      @location(1) texcoord: vec2<f32>,
\\  ) -> @location(0) vec4<f32> {
\\      let color = vec4(textureSample(img_tex, samp, texcoord).xyz, 1.0);
\\      return vec4(color.xyz, 1.0);
\\  }
;
// zig fmt: on
