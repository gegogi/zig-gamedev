const std = @import("std");
const math = std.math;
const sdl = @import("zsdl2");
const gl = @import("zopengl").bindings;
const xcommon = @import("xcommon");

pub const name = "generative art experiment: x0016";
pub const display_width = 1024 * 1;
pub const display_height = 1024 * 1;

const Vec2 = [2]f32;

var fs_postprocess: gl.Uint = 0;
var accum_tex: gl.Uint = 0;
var accum_fbo: gl.Uint = 0;
var prng = std.Random.DefaultPrng.init(0);
var random = prng.random();

const bounds: f32 = 3.0;
var y = -bounds;
var pass: u32 = 1;

pub fn draw() void {
    gl.enable(gl.BLEND);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, accum_fbo);
    gl.useProgram(0);

    gl.matrixLoadIdentityEXT(gl.PROJECTION);
    gl.matrixOrthoEXT(gl.PROJECTION, -bounds, bounds, -bounds, bounds, -1.0, 1.0);

    gl.loadIdentity();

    if (y <= bounds and pass == 1) {
        gl.color3f(0.001, 0.001, 0.001);
        gl.begin(gl.POINTS);
        const step: f32 = 0.001;
        var row: u32 = 0;
        while (row < 4) : (row += 1) {
            var x: f32 = -bounds;
            while (x <= bounds) : (x += step) {
                var v = Vec2{ x, y };
                v = sinusoidal(v, 2.4 + random.float(f32));
                gl.vertex2fv(&v);
            }
            y += step;
        }
        gl.end();
    }

    if (y >= bounds) {
        y = -bounds;
        pass += 1;
    }

    gl.disable(gl.BLEND);
    gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, xcommon.display_fbo);
    gl.useProgram(fs_postprocess);
    gl.matrixLoadIdentityEXT(gl.PROJECTION);
    gl.loadIdentity();
    gl.begin(gl.TRIANGLES);
    gl.vertex2f(-1.0, -1.0);
    gl.vertex2f(3.0, -1.0);
    gl.vertex2f(-1.0, 3.0);
    gl.end();
}

fn sinusoidal(v: Vec2, scale: f32) Vec2 {
    return .{ scale * math.sin(v[0]), scale * math.sin(v[1]) };
}

pub fn init() !void {
    try sdl.gl.setSwapInterval(1);

    gl.pointSize(3.0);

    gl.blendFunc(gl.ONE, gl.ONE);
    gl.blendEquation(gl.FUNC_ADD);

    gl.createTextures(gl.TEXTURE_2D, 1, &accum_tex);
    gl.textureStorage2D(accum_tex, 1, gl.RGBA16F, display_width, display_height);
    gl.clearTexImage(accum_tex, 0, gl.RGBA, gl.FLOAT, null);

    gl.createFramebuffers(1, &accum_fbo);
    gl.namedFramebufferTexture(accum_fbo, gl.COLOR_ATTACHMENT0, accum_tex, 0);

    const accum_texh = gl.getTextureHandleNV(accum_tex);
    gl.makeTextureHandleResidentNV(accum_texh);

    fs_postprocess = gl.createShaderProgramv(gl.FRAGMENT_SHADER, 1, &@as([*:0]const gl.Char, 
        \\  #version 460 compatibility
        \\  #extension NV_bindless_texture : require
        \\
        \\  layout(location = 0) uniform sampler2D accum_texh;
        \\
        \\  void main() {
        \\      vec3 color = texelFetch(accum_texh, ivec2(gl_FragCoord.xy), 0).rgb;
        \\      color = color / (color + 1.0);
        \\      color = 1.0 - color;
        \\      color = pow(color, vec3(2.2));
        \\      gl_FragColor = vec4(color, 1.0);
        \\  }
    ));
    gl.programUniformHandleui64NV(fs_postprocess, 0, accum_texh);
}
