package main

import wl "../../"
import "../../ext/libdecor"
import "base:runtime"
import "core:fmt"
import "core:os"
import gl "vendor:OpenGL"
import "vendor:egl"

state: struct {
	display:     ^wl.display,
	compositor:  ^wl.compositor,
	surface:     ^wl.surface,
	shm:         ^wl.shm,
	egl_window:  ^wl.egl_window,
	egl_display: egl.Display,
	egl_surface: egl.Surface,
	egl_context: egl.Context,
	instance:    ^libdecor.instance,
	frame:       ^libdecor.frame,
	size:        [2]int,
}

interface := libdecor.interface {
	error = interface_error,
}

frame_interface := libdecor.frame_interface {
	close     = frame_close,
	commit    = frame_commit,
	configure = frame_configure,
}

frame_close :: proc "c" (frame: ^libdecor.frame, user_data: rawptr) {
	os.exit(0)
}

frame_commit :: proc "c" (frame: ^libdecor.frame, user_data: rawptr) {
	egl.SwapBuffers(state.egl_display, state.egl_surface)
}

frame_configure :: proc "c" (frame: ^libdecor.frame, configuration: ^libdecor.configuration, user_data: rawptr) {
	context = runtime.default_context()

	width, height: int

	if !libdecor.configuration_get_content_size(configuration, frame, &width, &height) {
		width = 1280
		height = 720
	}

	wl.egl_window_resize(state.egl_window, width, height, 0, 0)

	libdecor_state := libdecor.state_new(width, height)
	libdecor.frame_commit(frame, libdecor_state, configuration)
	libdecor.state_free(libdecor_state)

	window_state: libdecor.window_state
	if libdecor.configuration_get_window_state(configuration, &window_state) do window_state = {}

	state.size = {width, height}
	gl.Viewport(0, 0, cast(i32)width, cast(i32)height)
}

interface_error :: proc "c" (instance: ^libdecor.instance, error: libdecor.error, message: cstring) {
	context = runtime.default_context()

	fmt.println("libdecor error", error, message)

	os.exit(1)
}

registry_handle_global :: proc "c" (
	data: rawptr,
	registry: ^wl.registry,
	name: uint,
	interface: cstring,
	version: uint,
) {
	context = runtime.default_context()

	if interface == wl.compositor_interface.name {
		state.compositor = cast(^wl.compositor)wl.registry_bind(registry, name, &wl.compositor_interface, 4)
	}
}

VERTEX: cstring = `
#version 330 core
layout (location = 0) in vec2 Position;

void main() {
    gl_Position = vec4(Position, 0.0, 1.0);
}
`


FRAGMENT: cstring = `
#version 330 core
out vec4 FragColor;

void main() {
    FragColor = vec4(1.0, 0.0, 0.0, 1.0);
}
`


main :: proc() {
	state.display = wl.display_connect(nil)

	if state.display == nil {
		fmt.println("Failed to connect to a wayland display")
		return
	}
	fmt.println("Successfully connected to a wayland display.")

	registry_listener := wl.registry_listener {
		global = registry_handle_global,
	}

	wl_registry := wl.display_get_registry(state.display)
	wl.registry_add_listener(wl_registry, &registry_listener, nil)
	wl.display_roundtrip(state.display)
	state.surface = wl.compositor_create_surface(state.compositor)

	major, minor: i32
	egl.BindAPI(egl.OPENGL_API)
	config_attribs := []i32{egl.RED_SIZE, 8, egl.GREEN_SIZE, 8, egl.BLUE_SIZE, 8, egl.NONE}

	state.egl_display = egl.GetDisplay(cast(egl.NativeDisplayType)state.display)
	if state.egl_display == nil {
		fmt.println("Failed to get EGL display")
		return
	}

	egl.Initialize(state.egl_display, &major, &minor)
	fmt.printfln("EGL Major: %v, EGL Minor: %v", major, minor)

	config: egl.Config
	num_config: i32

	egl.ChooseConfig(state.egl_display, raw_data(config_attribs), &config, 1, &num_config)
	state.egl_context = egl.CreateContext(state.egl_display, config, nil, nil)
	state.egl_window = wl.egl_window_create(state.surface, 1280, 720)
	state.egl_surface = egl.CreateWindowSurface(
		state.egl_display,
		config,
		cast(egl.NativeWindowType)state.egl_window,
		nil,
	)
	wl.surface_commit(state.surface)
	egl.MakeCurrent(state.egl_display, state.egl_surface, state.egl_surface, state.egl_context)
	gl.load_up_to(4, 5, egl.gl_set_proc_address)

	// Create shader program for triangle
	vertex_shader := gl.CreateShader(gl.VERTEX_SHADER)
	gl.ShaderSource(vertex_shader, 1, &VERTEX, nil)
	gl.CompileShader(vertex_shader)

	fragment_shader := gl.CreateShader(gl.FRAGMENT_SHADER)
	gl.ShaderSource(fragment_shader, 1, &FRAGMENT, nil)
	gl.CompileShader(fragment_shader)

	shader_program := gl.CreateProgram()
	gl.AttachShader(shader_program, vertex_shader)
	gl.AttachShader(shader_program, fragment_shader)
	gl.LinkProgram(shader_program)

	// Triangle vertices
	vertices := []f32 {
		-0.5,
		-0.5, // bottom left
		0.5,
		-0.5, // bottom right
		0.0,
		0.5, // top center
	}

	vao: u32
	vbo: u32
	gl.GenVertexArrays(1, &vao)
	gl.GenBuffers(1, &vbo)

	gl.BindVertexArray(vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, len(vertices) * size_of(f32), raw_data(vertices), gl.STATIC_DRAW)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 2 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)

	state.instance = libdecor.new(state.display, &interface)
	state.frame = libdecor.decorate(state.instance, state.surface, &frame_interface, nil)
	libdecor.frame_set_app_id(state.frame, "widgets")
	libdecor.frame_set_title(state.frame, "widgets")
	libdecor.frame_map(state.frame)
	wl.display_dispatch(state.display)
	wl.display_dispatch(state.display)
	for wl.display_dispatch_pending(state.display) != -1 {
		gl.ClearColor(0, 0, 1, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		// Draw triangle
		gl.UseProgram(shader_program)
		gl.BindVertexArray(vao)
		gl.DrawArrays(gl.TRIANGLES, 0, 3)

		egl.SwapBuffers(state.egl_display, state.egl_surface)
	}
}
