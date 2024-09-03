extends MeshInstance3D

@export var print_times = false
@export var workgroup_size: int = 8
@export_range(-1.0, 1.0) var isolevel: float = 0.0
@export var noise: Noise

const resolution = 8   # To update this, also update the local size in the marching cube shader

var grid = []

var rd: RenderingDevice
var uniform_set: RID
var pipeline: RID
var input_buffer: RID
var counter_buffer: RID
var counter_bytes_size: int
var vertices_buffer: RID
var normals_buffer: RID
var output_bytes_size: int

var vertices: PackedVector3Array
var normals: PackedVector3Array
var array_mesh: ArrayMesh

var data_fetching_thread: Thread
var mesh_creation_thread: Thread
var mutex: Mutex
var should_update_mesh: bool

func sample_noise():
	for x in workgroup_size * resolution + 1:
		for y in workgroup_size * resolution + 1:
			for z in workgroup_size * resolution + 1:
				grid.append(noise.get_noise_3d(
					float(x),
					float(y),
					float(z)
				))

func init_compute():
	rd = RenderingServer.create_local_rendering_device()
	var shader_file = load("res://marching_cubes.glsl")
	var shader_spirv = shader_file.get_spirv()
	var shader = rd.shader_create_from_spirv(shader_spirv)

	# Input
	var input_bytes = PackedFloat32Array(grid).to_byte_array()
	input_buffer = rd.storage_buffer_create(input_bytes.size(), input_bytes)

	var input_uniform = RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_uniform.binding = 0
	input_uniform.add_id(input_buffer)

	# Vertices
	const max_tris_per_voxel : int = 5
	var max_triangles : int = max_tris_per_voxel * int(pow(resolution * workgroup_size, 3))
	const bytes_per_float : int = 4
	const floats_per_triangle : int = 3 * 3
	const bytes_per_triangle : int = floats_per_triangle * bytes_per_float
	output_bytes_size = 8 + bytes_per_triangle * max_triangles

	vertices_buffer = rd.storage_buffer_create(output_bytes_size)

	var vertices_uniform = RDUniform.new()
	vertices_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertices_uniform.binding = 1
	vertices_uniform.add_id(vertices_buffer)

	# Normals
	normals_buffer = rd.storage_buffer_create(output_bytes_size)

	var normals_uniform = RDUniform.new()
	normals_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	normals_uniform.binding = 2
	normals_uniform.add_id(normals_buffer)

	# Parameters
	var parameters_bytes = PackedFloat32Array([resolution, isolevel]).to_byte_array()
	var parameters_buffer = rd.storage_buffer_create(parameters_bytes.size(), parameters_bytes)

	var parameters_uniform = RDUniform.new()
	parameters_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	parameters_uniform.binding = 3
	parameters_uniform.add_id(parameters_buffer)

	# Counter
	var counter_bytes = PackedInt32Array([0]).to_byte_array()
	counter_bytes_size = counter_bytes.size()
	counter_buffer = rd.storage_buffer_create(counter_bytes_size, counter_bytes)

	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 4
	counter_uniform.add_id(counter_buffer)

	uniform_set = rd.uniform_set_create([input_uniform, vertices_uniform, normals_uniform, parameters_uniform, counter_uniform], shader, 0)

	pipeline = rd.compute_pipeline_create(shader)

func run_compute():
	while true:
		var start = Time.get_ticks_msec()

		rd.buffer_update(input_buffer, 0, grid.size(), PackedFloat32Array(grid).to_byte_array())
		rd.buffer_update(counter_buffer, 0, counter_bytes_size, PackedFloat32Array([0]).to_byte_array())
		rd.buffer_clear(vertices_buffer, 0, output_bytes_size)

		var compute_list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		rd.compute_list_dispatch(compute_list, workgroup_size, workgroup_size, workgroup_size)
		rd.compute_list_end()

		rd.submit()
		rd.sync()

		var mid = Time.get_ticks_msec()
		if print_times:
			print("Compute shader: ", mid - start)

		var raw_vertices_bytes = rd.buffer_get_data(vertices_buffer)
		var raw_normals_bytes = rd.buffer_get_data(normals_buffer)
		var output_counter = rd.buffer_get_data(counter_buffer).to_int32_array()[0]

		if print_times:
			print("num triangles to add:", output_counter)

		var vertex_count = output_counter * 3

		raw_vertices_bytes[0] = 36
		raw_vertices_bytes[1] = 0
		raw_vertices_bytes[2] = 0
		raw_vertices_bytes[3] = 0
		raw_vertices_bytes[4] = vertex_count & 0x000000FF
		raw_vertices_bytes[5] = (vertex_count & 0x0000FF00) >> 8
		raw_vertices_bytes[6] = (vertex_count & 0x00FF0000) >> 16
		raw_vertices_bytes[7] = (vertex_count & 0xFF000000) >> 24

		raw_normals_bytes[0] = 36
		raw_normals_bytes[1] = 0
		raw_normals_bytes[2] = 0
		raw_normals_bytes[3] = 0
		raw_normals_bytes[4] = vertex_count & 0x000000FF
		raw_normals_bytes[5] = (vertex_count & 0x0000FF00) >> 8
		raw_normals_bytes[6] = (vertex_count & 0x00FF0000) >> 16
		raw_normals_bytes[7] = (vertex_count & 0xFF000000) >> 24

		vertices = bytes_to_var(raw_vertices_bytes)
		normals = bytes_to_var(raw_normals_bytes)

		mutex.lock()
		should_update_mesh = true
		mutex.unlock()

		if print_times:
			print("Vertex/Normals treatment: ", Time.get_ticks_msec() - mid)
			print("Total compute time: ", Time.get_ticks_msec() - start)

func update_mesh():
	var start = Time.get_ticks_msec()

	var mesh_data = []
	mesh_data.resize(Mesh.ARRAY_MAX)
	mesh_data[Mesh.ARRAY_VERTEX] = vertices
	mesh_data[Mesh.ARRAY_NORMAL] = normals
	array_mesh.clear_surfaces()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_data)

	if print_times:
		print("Mesh creation: ", Time.get_ticks_msec() - start)


func update_collisions():
	var start = Time.get_ticks_msec()

	# var body = PhysicsServer3D.body_create()
	# PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	# PhysicsServer3D.body_set_space(body, get_world_3d().space)
	# PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D())
	# PhysicsServer3D.body_set_collision_layer(body, 1)
	# PhysicsServer3D.body_set_collision_mask(body, 1)
	# var shape = PhysicsServer3D.concave_polygon_shape_create()
	# PhysicsServer3D.shape_set_data(shape, {"faces": vertices})
	# PhysicsServer3D.body_add_shape(body, shape)

	var shape2: CollisionShape3D = $StaticBody3D/CollisionShape3D
	shape2.shape.set_faces(vertices)

	if print_times:
		print("Collision creation: ", Time.get_ticks_msec() - start)

func _ready() -> void:
	array_mesh = ArrayMesh.new()
	mesh = array_mesh
	randomize()
	sample_noise()
	init_compute()

	should_update_mesh = false
	mutex = Mutex.new()
	data_fetching_thread = Thread.new()
	mesh_creation_thread = Thread.new()

	data_fetching_thread.start(run_compute)

func _process(_delta: float) -> void:
	if should_update_mesh:
		update_mesh()
		update_collisions()

		mutex.lock()
		should_update_mesh = false
		mutex.unlock()


func _on_camera_3d_dig_signal(at: Vector3) -> void:
	var c = at.round()
	var dim = resolution * workgroup_size + 1
	grid[c.z + c.y * dim + c.x * dim * dim] += 0.1
