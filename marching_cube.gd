extends Node3D

@export var workgroup_size: int = 8
@export_range(-1.0, 1.0) var isolevel: float = 0.0
@export var noise: Noise

const resolution = 8   # To update this, also update the local size in the marching cube shader

var grid = []

var rd: RenderingDevice
var uniform_set: RID
var pipeline: RID
var counter_buffer: RID
var counter_bytes_size: int
var output_buffer: RID
var output_bytes_size: int

var mesh_instance: MeshInstance3D

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
	var input_buffer = rd.storage_buffer_create(input_bytes.size(), input_bytes)

	var input_uniform = RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_uniform.binding = 0
	input_uniform.add_id(input_buffer)

	# Output
	const max_tris_per_voxel : int = 5
	var max_triangles : int = max_tris_per_voxel * int(pow(resolution * workgroup_size, 3))
	const bytes_per_float : int = 4
	const floats_per_triangle : int = 4 * 3
	const bytes_per_triangle : int = floats_per_triangle * bytes_per_float
	output_bytes_size = bytes_per_triangle * max_triangles

	output_buffer = rd.storage_buffer_create(output_bytes_size)

	var output_uniform = RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output_uniform.binding = 1
	output_uniform.add_id(output_buffer)

	# Parameters
	var parameters_bytes = PackedFloat32Array([resolution, isolevel]).to_byte_array()
	var parameters_buffer = rd.storage_buffer_create(parameters_bytes.size(), parameters_bytes)

	var parameters_uniform = RDUniform.new()
	parameters_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	parameters_uniform.binding = 2
	parameters_uniform.add_id(parameters_buffer)

	# Counter
	var counter_bytes = PackedInt32Array([0]).to_byte_array()
	counter_bytes_size = counter_bytes.size()
	counter_buffer = rd.storage_buffer_create(counter_bytes_size, counter_bytes)

	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 3
	counter_uniform.add_id(counter_buffer)

	uniform_set = rd.uniform_set_create([input_uniform, output_uniform, parameters_uniform, counter_uniform], shader, 0)

	pipeline = rd.compute_pipeline_create(shader)

func run_compute():
	rd.buffer_update(counter_buffer, 0, counter_bytes_size, PackedFloat32Array([0]).to_byte_array())
	rd.buffer_clear(output_buffer, 0, output_bytes_size)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, workgroup_size, workgroup_size, workgroup_size)
	rd.compute_list_end()

	rd.submit()
	rd.sync()

	var output_bytes = rd.buffer_get_data(output_buffer)
	var output = output_bytes.to_float32_array()
	var output_counter_bytes = rd.buffer_get_data(counter_buffer)
	var output_counter = output_counter_bytes.to_int32_array()[0]

	print("num triangles to add:", output_counter)

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in output_counter:
		var index = i * 12
		var a = Vector3(output[index], output[index + 1], output[index + 2])
		var b = Vector3(output[index + 4], output[index + 5], output[index + 6])
		var c = Vector3(output[index + 8], output[index + 9], output[index + 10])
		st.add_vertex(a)
		st.add_vertex(b)
		st.add_vertex(c)
	st.generate_normals()
	var mesh = st.commit()
	
	mesh_instance.mesh = mesh


func _ready() -> void:
	mesh_instance = MeshInstance3D.new()
	add_child(mesh_instance)
	randomize()
	sample_noise()
	init_compute()


func _process(_delta: float) -> void:
	run_compute()
