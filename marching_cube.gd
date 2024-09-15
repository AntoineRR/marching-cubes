extends Node3D

@export var chunks: int = 8
@export var print_times = false
@export var print_triangles_number = false
@export_range(-1.0, 1.0) var isolevel: float = 0.0
@export var noise: Noise
@export_range(0.0, 5.0) var voxel_dimension: float = 1.0
@export_range(-0.1, 0.1) var digging_power: float = 0.01
@export_range(0.0, 10.0) var digging_radius: float = 2.0
@export var digging_curve: Curve

const workgroup_size = 2
const local_size = 4   # To update this, also update the local size in the marching cube shader

var grid = []

var rd: RenderingDevice
var uniform_set: RID
var pipeline: RID
var input_buffer: RID
var counter_buffer: RID
var vertices_buffer: RID
var normals_buffer: RID
var triangles_by_voxels_buffer: RID
var parameters_buffer: RID
var output_bytes_size: int

var vertices: PackedVector3Array
var normals: PackedVector3Array

var meshes = []
var collisions = []

func sample_noise(offset: Vector3, grid_index: int):
	for x in range(offset.x, offset.x + workgroup_size * local_size + 1):
		for y in range(offset.y, offset.y + workgroup_size * local_size + 1):
			for z in range(offset.z, offset.z + workgroup_size * local_size + 1):
				grid[grid_index].append(noise.get_noise_3d(
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
	var input_bytes = PackedFloat32Array(grid[0]).to_byte_array()
	input_buffer = rd.storage_buffer_create(input_bytes.size(), input_bytes)

	var input_uniform = RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_uniform.binding = 0
	input_uniform.add_id(input_buffer)

	# Vertices
	const max_tris_per_voxel : int = 5
	var max_triangles : int = max_tris_per_voxel * int(pow(local_size * workgroup_size, 3))
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
	var parameters_bytes = PackedFloat32Array([local_size, isolevel, 0, 0, 0, voxel_dimension]).to_byte_array()
	parameters_buffer = rd.storage_buffer_create(parameters_bytes.size(), parameters_bytes)

	var parameters_uniform = RDUniform.new()
	parameters_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	parameters_uniform.binding = 3
	parameters_uniform.add_id(parameters_buffer)

	# Counter
	var counter_bytes = PackedInt32Array([0]).to_byte_array()
	counter_buffer = rd.storage_buffer_create(counter_bytes.size(), counter_bytes)

	var counter_uniform = RDUniform.new()
	counter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counter_uniform.binding = 4
	counter_uniform.add_id(counter_buffer)

	uniform_set = rd.uniform_set_create(
		[input_uniform, vertices_uniform, normals_uniform, parameters_uniform, counter_uniform],
		shader,
		0
	)

	pipeline = rd.compute_pipeline_create(shader)

func run_compute(offset: Vector3, grid_index: int):
	var grid_bytes = PackedFloat32Array(grid[grid_index]).to_byte_array()
	rd.buffer_update(input_buffer, 0, grid_bytes.size(), grid_bytes)
	rd.buffer_update(counter_buffer, 0, 4, PackedFloat32Array([0]).to_byte_array())
	rd.buffer_update(parameters_buffer, 8, 12, PackedVector3Array([offset.x, offset.y, offset.z]).to_byte_array())
	rd.buffer_clear(vertices_buffer, 0, output_bytes_size)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, workgroup_size, workgroup_size, workgroup_size)
	rd.compute_list_end()

	rd.submit()
	rd.sync()

	var raw_vertices_bytes = rd.buffer_get_data(vertices_buffer)
	var raw_normals_bytes = rd.buffer_get_data(normals_buffer)
	var output_counter = rd.buffer_get_data(counter_buffer).to_int32_array()[0]

	if print_triangles_number:
		print("num triangles to add:", output_counter)

	var vertex_count = output_counter * 3

	# Magic numbers for a Vector3 array
	raw_vertices_bytes[0] = 36
	raw_vertices_bytes[1] = 0
	raw_vertices_bytes[2] = 0
	raw_vertices_bytes[3] = 0
	# Size of the array in 4 bytes
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

func update_mesh(mesh_index: int):
	if vertices and normals:
		var mesh_data = []
		mesh_data.resize(Mesh.ARRAY_MAX)
		mesh_data[Mesh.ARRAY_VERTEX] = vertices
		mesh_data[Mesh.ARRAY_NORMAL] = normals
		meshes[mesh_index].mesh.clear_surfaces()
		meshes[mesh_index].mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_data)


func update_collisions(grid_index: int):
	collisions[grid_index].shape.set_faces(vertices)

func _ready() -> void:
	randomize()

	for i in chunks:
		for j in chunks:
			for k in chunks:
				var mesh = ArrayMesh.new()
				var mesh_instance = MeshInstance3D.new()
				mesh_instance.mesh = mesh
				mesh_instance.position = Vector3(i, j, k) * local_size * workgroup_size * voxel_dimension
				add_child(mesh_instance)
				meshes.append(mesh_instance)

				var collision = StaticBody3D.new()
				var shape = CollisionShape3D.new()
				shape.shape = ConcavePolygonShape3D.new()
				collision.add_child(shape)
				collision.position = Vector3(i, j, k) * local_size * workgroup_size * voxel_dimension
				add_child(collision)
				collisions.append(shape)

				grid.append([])
				sample_noise(Vector3(i, j, k) * local_size * workgroup_size, k + j*chunks + i*chunks*chunks)
	
	init_compute()
	
	for i in chunks:
		for j in chunks:
			for k in chunks:
				var offset = Vector3(i, j, k) * local_size * workgroup_size * voxel_dimension
				var grid_index = k + j*chunks + i*chunks*chunks
				run_compute(offset, grid_index)
				update_mesh(grid_index)
				update_collisions(grid_index)


func voxel_coord_to_chunk_coord(coord: Vector3i) -> Vector3i:
	return Vector3i(coord / (local_size * workgroup_size))


func chunk_coord_to_chunk_index(chunk_coord: Vector3i) -> int:
	return chunk_coord.z + chunk_coord.y * chunks + chunk_coord.x * chunks * chunks


func point_coord_to_point_coord_in_chunk(point_coord: Vector3i, chunk_coord: Vector3i) -> Vector3i:
	var min_chunk_point = chunk_coord * local_size * workgroup_size
	return point_coord - min_chunk_point


func point_coord_in_chunk_to_point_index(point_coord_in_chunk: Vector3i) -> int:
	var chunk_dim = local_size * workgroup_size + 1
	return point_coord_in_chunk.z + point_coord_in_chunk.y * chunk_dim + point_coord_in_chunk.x * chunk_dim * chunk_dim


func point_coord_to_point_position(point_coord: Vector3i) -> Vector3:
	return point_coord * voxel_dimension


func chunk_coord_to_chunk_position(chunk_coord: Vector3i) -> Vector3:
	return chunk_coord * local_size * workgroup_size * voxel_dimension


func modify_grid_point(chunk_coord: Vector3i, point_coord_in_chunk: Vector3i, value_to_add: float):
	var chunk_index = chunk_coord_to_chunk_index(chunk_coord)
	var point_index = point_coord_in_chunk_to_point_index(point_coord_in_chunk)
	grid[chunk_index][point_index] += value_to_add


func _on_camera_3d_dig_signal(at: Vector3) -> void:
	var start_time = Time.get_ticks_msec()

	var cube_extent = round(digging_radius / voxel_dimension + 0.5)
	var c = Vector3i(at / voxel_dimension)  # Coords of the voxel hit
	var chunk_dim = local_size * workgroup_size
	var voxel_dim = chunk_dim * chunks
	var chunks_to_reload = {}
	var point_coords_to_modify = {}

	# Check every voxel in the radius around the voxel hit
	for i in range(max(c.x - cube_extent, 0), min(c.x + cube_extent + 1, voxel_dim)):
		for j in range(max(c.y - cube_extent, 0), min(c.y + cube_extent + 1, voxel_dim)):
			for k in range(max(c.z - cube_extent, 0), min(c.z + cube_extent + 1, voxel_dim)):
				var voxel_coord = Vector3i(i, j, k)
				var chunk_coord = voxel_coord_to_chunk_coord(voxel_coord)
				# Check all 8 corners of the voxel
				for point_coord in [
					Vector3i(voxel_coord.x, voxel_coord.y, voxel_coord.z),
					Vector3i(voxel_coord.x + 1, voxel_coord.y, voxel_coord.z),
					Vector3i(voxel_coord.x, voxel_coord.y, voxel_coord.z + 1),
					Vector3i(voxel_coord.x + 1, voxel_coord.y, voxel_coord.z + 1),
					Vector3i(voxel_coord.x, voxel_coord.y + 1, voxel_coord.z),
					Vector3i(voxel_coord.x + 1, voxel_coord.y + 1, voxel_coord.z),
					Vector3i(voxel_coord.x, voxel_coord.y + 1, voxel_coord.z + 1),
					Vector3i(voxel_coord.x + 1, voxel_coord.y + 1, voxel_coord.z + 1),
				]:
					var point_position = point_coord_to_point_position(point_coord)
					var distance = point_position.distance_to(at)
					if distance <= digging_radius:
						point_coords_to_modify[[point_coord, chunk_coord]] = digging_power * digging_curve.sample_baked(distance / digging_radius)
						chunks_to_reload[chunk_coord] = null
	
	for point_info in point_coords_to_modify:
		var point_coord = point_info[0]
		var chunk_coord = point_info[1]
		var value = point_coords_to_modify[point_info]
		var point_coord_in_chunk = point_coord_to_point_coord_in_chunk(point_coord, chunk_coord)
		modify_grid_point(chunk_coord, point_coord_in_chunk, value)

	for chunk_coord in chunks_to_reload:
		var grid_index = chunk_coord_to_chunk_index(chunk_coord)
		run_compute(chunk_coord_to_chunk_position(chunk_coord), grid_index)
		update_mesh(grid_index)
		update_collisions(grid_index)
	
	if print_times:
		print("Recalculation time: ", Time.get_ticks_msec() - start_time)
