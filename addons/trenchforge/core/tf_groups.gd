class_name TFGroups
extends RefCounted
## Brush groups: plain Node3D nodes between a TFMap and its brushes. A group
## is selected as a whole until it is entered (double click); nested groups
## work the same way one level at a time.
##
## Compounds (Verbünde) are groups with the metadata TFConst.META_COMPOUND:
## shapes split into convex brushes that should behave like one object
## (outline and logical faces, see TFCompound). Compounds are never nested.


## True for Node3D nodes below the map that organize brushes (not brushes,
## not the build output).
static func is_group(node: Node, map: TFMap) -> bool:
	# Groups are plain Node3D; meshes, lights or bodies (e.g. baked meshes)
	# placed under the map are not.
	if node == null or node.get_class() != "Node3D" or node is TFBrush or node is TFMap or map == null:
		return false
	if not map.is_ancestor_of(node):
		return false
	var build := map.get_build_root()
	return build == null or (node != build and not build.is_ancestor_of(node))


## True for a compound node (a plain Node3D with the compound metadata).
## Whether it lies below a map is checked by is_group().
static func is_compound(node: Node) -> bool:
	return node != null and node.get_class() == "Node3D" and not node is TFBrush and not node is TFMap \
		and node.get_script() == null and bool(node.get_meta(TFConst.META_COMPOUND, false))


## The node itself or its nearest ancestor that is a compound (below the
## map), else null.
static func compound_of(node: Node) -> Node3D:
	while node != null and not node is TFMap:
		if is_compound(node):
			return node as Node3D
		node = node.get_parent()
	return null


## New, empty compound node (detached).
static func new_compound() -> Node3D:
	var node := Node3D.new()
	node.name = TFConst.COMPOUND_NODE_NAME
	node.set_meta(TFConst.META_COMPOUND, true)
	return node


## The node a click on the brush selects: the brush itself or its outermost
## group inside the container (the entered group, or the map). Returns the
## outermost group below the map if the brush lies outside the container.
static func selectable_for(brush: TFBrush, map: TFMap, entered: Node3D = null) -> Node3D:
	var container: Node = entered if entered != null and entered.is_ancestor_of(brush) else map
	var node: Node = brush
	while node.get_parent() != null and node.get_parent() != container and node.get_parent() != map:
		node = node.get_parent()
	return node as Node3D


## Brushes of a node: the brush itself or all brushes below a group.
static func brushes_of(node: Node) -> Array[TFBrush]:
	var result: Array[TFBrush] = []
	if node is TFBrush:
		result.append(node)
		return result
	for child in node.get_children():
		result.append_array(brushes_of(child))
	return result


## Common parent for a new group: the shared parent of all nodes, else the
## fallback (map or entered group).
static func common_parent(nodes: Array, fallback: Node) -> Node:
	if nodes.is_empty():
		return fallback
	var parent: Node = (nodes[0] as Node).get_parent()
	for node: Node in nodes:
		if node.get_parent() != parent:
			return fallback
	return parent


## Groups the nodes into a new Node3D below parent as one undoable action.
## Returns the new (detached until the action is done) group.
static func group(undo_redo: Object, action_name: String, nodes: Array, parent: Node, scene_owner: Node) -> Node3D:
	var new_group := Node3D.new()
	new_group.name = TFConst.GROUP_NODE_NAME
	undo_redo.create_action(action_name)
	TFUndo.add_do_method(undo_redo, parent, &"add_child", [new_group, true])
	undo_redo.add_do_property(new_group, &"owner", scene_owner)
	var parents: Array = []
	parents.resize(nodes.size())
	parents.fill(new_group)
	TFUndo.record_reparent(undo_redo, nodes, parents)
	TFUndo.add_undo_method(undo_redo, parent, &"remove_child", [new_group])
	undo_redo.add_do_reference(new_group)
	undo_redo.commit_action()
	return new_group


## Groups the nodes into a new compound below parent as one undoable action.
## Compounds among the nodes or below them become plain groups (compounds are
## never nested). Returns the new compound.
static func make_compound(undo_redo: Object, action_name: String, nodes: Array, parent: Node, scene_owner: Node) -> Node3D:
	var compound := new_compound()
	undo_redo.create_action(action_name)
	TFUndo.add_do_method(undo_redo, parent, &"add_child", [compound, true])
	undo_redo.add_do_property(compound, &"owner", scene_owner)
	var parents: Array = []
	parents.resize(nodes.size())
	parents.fill(compound)
	TFUndo.record_reparent(undo_redo, nodes, parents)
	_record_unmark_inner(undo_redo, nodes)
	TFUndo.add_undo_method(undo_redo, parent, &"remove_child", [compound])
	undo_redo.add_do_reference(compound)
	undo_redo.commit_action()
	return compound


## Turns an existing group into a compound as one undoable action
## (compounds below it become plain groups).
static func mark_compound(undo_redo: Object, action_name: String, group_node: Node3D) -> void:
	undo_redo.create_action(action_name)
	TFUndo.add_do_method(undo_redo, group_node, &"set_meta", [TFConst.META_COMPOUND, true])
	TFUndo.add_undo_method(undo_redo, group_node, &"remove_meta", [TFConst.META_COMPOUND])
	_record_unmark_inner(undo_redo, group_node.get_children())
	undo_redo.commit_action()


static func _record_unmark_inner(undo_redo: Object, nodes: Array) -> void:
	for node: Node in nodes:
		for inner: Node in [node] + TFUndo.descendants(node):
			if is_compound(inner):
				TFUndo.add_do_method(undo_redo, inner, &"remove_meta", [TFConst.META_COMPOUND])
				TFUndo.add_undo_method(undo_redo, inner, &"set_meta", [TFConst.META_COMPOUND, true])


## Dissolves groups: their children move to the group's parent (in place of
## the group), the group node is removed. One undoable action. Returns the
## former members.
static func ungroup(undo_redo: Object, action_name: String, groups: Array) -> Array[Node]:
	var members: Array[Node] = []
	undo_redo.create_action(action_name)
	for group_node: Node3D in groups:
		var parent := group_node.get_parent()
		var index := group_node.get_index()
		var children := group_node.get_children()
		for i in children.size():
			TFUndo.add_do_method(undo_redo, children[i], &"reparent", [parent, true])
			TFUndo.add_do_method(undo_redo, parent, &"move_child", [children[i], index + i])
			members.append(children[i])
		undo_redo.add_do_property(group_node, &"owner", null)
		TFUndo.add_do_method(undo_redo, parent, &"remove_child", [group_node])
		TFUndo.add_undo_method(undo_redo, parent, &"add_child", [group_node, true])
		TFUndo.add_undo_method(undo_redo, parent, &"move_child", [group_node, index])
		undo_redo.add_undo_property(group_node, &"owner", group_node.owner)
		for child in children:
			TFUndo.add_undo_method(undo_redo, child, &"reparent", [group_node, true])
		undo_redo.add_undo_reference(group_node)
	undo_redo.commit_action()
	return members


## Detached deep copy of a brush or group (faces are copied, never shared).
static func duplicate_node(node: Node) -> Node:
	if node is TFBrush:
		return TFUndo.duplicate_brush(node)
	if not node is Node3D or node.get_class() != "Node3D" or node.get_script() != null:
		return node.duplicate()
	var copy := Node3D.new()
	copy.name = node.name
	copy.transform = (node as Node3D).transform
	if is_compound(node):
		copy.set_meta(TFConst.META_COMPOUND, true)
	if node.has_meta(TFConst.META_SHAPE):
		copy.set_meta(TFConst.META_SHAPE, node.get_meta(TFConst.META_SHAPE).duplicate())
	for child in node.get_children():
		copy.add_child(duplicate_node(child), true)
	return copy
