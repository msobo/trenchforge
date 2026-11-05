class_name TFUndo
extends RefCounted
## Undo/redo helpers. Every mutation of the data model goes through here.
##
## undo_redo is an EditorUndoRedoManager (or UndoRedo); it is typed as Object
## so core/ stays free of editor APIs and testable headless.


## Deep copy of a brush's faces, safe to store in undo history.
static func snapshot_faces(brush: TFBrush) -> Array[TFFace]:
	return copy_faces(brush.faces)


## Records "old faces -> new faces" for one brush as a single action.
## old_faces should be a snapshot taken before any live preview changes.
static func commit_faces(undo_redo: Object, action_name: String, brush: TFBrush, old_faces: Array[TFFace], new_faces: Array[TFFace]) -> void:
	commit_many_faces(undo_redo, action_name, [brush], [old_faces], [new_faces])


## Records face changes for several brushes as a single action.
static func commit_many_faces(undo_redo: Object, action_name: String, brushes: Array, old_faces: Array, new_faces: Array) -> void:
	undo_redo.create_action(action_name)
	for i in brushes.size():
		undo_redo.add_do_property(brushes[i], &"faces", copy_faces(new_faces[i]))
		undo_redo.add_undo_property(brushes[i], &"faces", copy_faces(old_faces[i]))
	undo_redo.commit_action()


## Like commit_many_faces(), but returns the face arrays the action applies
## on redo: replace_committed_faces() changes the result of this action in
## place, so adjusting it afterwards (bevel panel) keeps one history entry.
static func commit_replaceable_faces(undo_redo: Object, action_name: String, brushes: Array, old_faces: Array, new_faces: Array) -> Array:
	var applied: Array = []
	undo_redo.create_action(action_name)
	for i in brushes.size():
		var faces := copy_faces(new_faces[i])
		applied.append(faces)
		undo_redo.add_do_property(brushes[i], &"faces", faces)
		undo_redo.add_undo_property(brushes[i], &"faces", copy_faces(old_faces[i]))
	undo_redo.commit_action()
	return applied


## Gives the brushes new faces now and on every later redo of the action
## that commit_replaceable_faces() returned applied for; its undo still
## restores the old faces.
static func replace_committed_faces(brushes: Array, applied: Array, new_faces: Array) -> void:
	for i in brushes.size():
		# The brush holds the applied array since the commit: give it its
		# own copy first, then change what redo applies.
		brushes[i].faces = copy_faces(new_faces[i])
		(applied[i] as Array).assign(copy_faces(new_faces[i]))


## Records position changes for several brushes as a single action.
static func move_brushes(undo_redo: Object, action_name: String, brushes: Array, old_positions: Array, new_positions: Array) -> void:
	undo_redo.create_action(action_name)
	for i in brushes.size():
		undo_redo.add_do_property(brushes[i], &"position", new_positions[i])
		undo_redo.add_undo_property(brushes[i], &"position", old_positions[i])
	undo_redo.commit_action()


## Records combined face and position changes (e.g. rotation) as one action.
static func transform_brushes(undo_redo: Object, action_name: String, brushes: Array, old_faces: Array, new_faces: Array, old_positions: Array, new_positions: Array) -> void:
	undo_redo.create_action(action_name)
	for i in brushes.size():
		undo_redo.add_do_property(brushes[i], &"faces", copy_faces(new_faces[i]))
		undo_redo.add_do_property(brushes[i], &"position", new_positions[i])
		undo_redo.add_undo_property(brushes[i], &"faces", copy_faces(old_faces[i]))
		undo_redo.add_undo_property(brushes[i], &"position", old_positions[i])
	undo_redo.commit_action()


## Adds a new brush under parent as one undoable action.
static func add_brush(undo_redo: Object, action_name: String, parent: Node, brush: TFBrush, scene_owner: Node) -> void:
	add_brushes(undo_redo, action_name, [parent], [brush], scene_owner)


## Adds several new brushes (parents[i] receives brushes[i]) as one action.
static func add_brushes(undo_redo: Object, action_name: String, parents: Array, brushes: Array, scene_owner: Node) -> void:
	undo_redo.create_action(action_name)
	_record_add(undo_redo, parents, brushes, scene_owner)
	undo_redo.commit_action()


## Removes brushes (or groups) from the scene as one undoable action.
## Compounds left with at most one brush are dissolved.
static func remove_brushes(undo_redo: Object, action_name: String, brushes: Array) -> void:
	replace_brushes(undo_redo, action_name, [], [], [], [], brushes, null)


## Face changes, new brushes (parents[i] receives added[i]) and removed
## brushes as one undoable action (clip and CSG operations).
##
## Compounds that end up with at most one brush are dissolved in the same
## action. Options:
##   "new_compounds": Array of [compound, source]: the detached compound (see
##       TFGroups.new_compound()) takes the place of the brush source, which
##       moves into it; added brushes may use the compound as parent.
##   "extra_compounds": compounds to check for dissolving as well.
##   "meta": Array of [node, name, value]: metadata to set (null removes).
##   "merge_mode": UndoRedo.MergeMode of the action (default MERGE_DISABLE).
static func replace_brushes(undo_redo: Object, action_name: String, changed: Array, new_faces: Array, parents: Array, added: Array, removed: Array, scene_owner: Node, options: Dictionary = {}) -> void:
	var new_compounds: Array = options.get("new_compounds", [])
	var dissolves := compound_dissolves(parents, added, removed, options.get("extra_compounds", []))
	undo_redo.create_action(action_name, options.get("merge_mode", UndoRedo.MERGE_DISABLE))
	for entry: Array in new_compounds:
		_record_new_compound_do(undo_redo, entry[0], entry[1], scene_owner)
	for i in changed.size():
		undo_redo.add_do_property(changed[i], &"faces", copy_faces(new_faces[i]))
		undo_redo.add_undo_property(changed[i], &"faces", snapshot_faces(changed[i]))
	for entry: Array in options.get("meta", []):
		_record_meta(undo_redo, entry[0], entry[1], entry[2])
	# Undo (runs in order) first brings dissolved compounds back, so the
	# brushes restored after them find their parent in the tree.
	for entry: Array in dissolves:
		_record_dissolve_undo(undo_redo, entry[0], entry[1])
	_record_add(undo_redo, parents, added, scene_owner)
	for entry: Array in dissolves:
		_record_dissolve_do(undo_redo, entry[0], entry[1])
	_record_remove(undo_redo, removed)
	for entry: Array in dissolves:
		add_undo_method(undo_redo, entry[0].get_parent(), &"move_child", [entry[0], entry[0].get_index()])
	for entry: Array in new_compounds:
		_record_new_compound_undo(undo_redo, entry[0], entry[1])
	undo_redo.commit_action()


static func _record_meta(undo_redo: Object, node: Node, meta_name: StringName, value: Variant) -> void:
	if value == null:
		add_do_method(undo_redo, node, &"remove_meta", [meta_name])
	else:
		add_do_method(undo_redo, node, &"set_meta", [meta_name, value])
	if node.has_meta(meta_name):
		add_undo_method(undo_redo, node, &"set_meta", [meta_name, node.get_meta(meta_name)])
	else:
		add_undo_method(undo_redo, node, &"remove_meta", [meta_name])


## Compounds that the operation leaves with at most one brush, as
## [compound, remaining direct children], highest index first. Candidates
## are the compounds of removed brushes and of new parents plus extra.
static func compound_dissolves(parents: Array, added: Array, removed: Array, extra: Array = []) -> Array:
	var candidates: Array = []
	for node: Node in extra:
		if not candidates.has(node):
			candidates.append(node)
	for node: Node in removed:
		var compound := TFGroups.compound_of(node.get_parent())
		if compound != null and not candidates.has(compound):
			candidates.append(compound)
	for parent: Node in parents:
		var compound := TFGroups.compound_of(parent)
		if compound != null and not candidates.has(compound):
			candidates.append(compound)
	var result: Array = []
	for compound: Node in candidates:
		if not compound.is_inside_tree() or _inside_any(compound, removed):
			continue
		var count := 0
		for brush in TFGroups.brushes_of(compound):
			if not _inside_any(brush, removed):
				count += 1
		var children: Array = []
		for child in compound.get_children():
			if not removed.has(child):
				children.append(child)
		for i in added.size():
			if parents[i] == compound:
				children.append(added[i])
			if parents[i] == compound or compound.is_ancestor_of(parents[i]):
				count += TFGroups.brushes_of(added[i]).size()
		if count <= 1:
			result.append([compound, children])
	# Dissolving moves children into the parent at the compound's index:
	# going from high to low indices keeps the lower ones valid.
	result.sort_custom(func(a: Array, b: Array) -> bool: return a[0].get_index() > b[0].get_index())
	return result


## True if node is one of the nodes or lies below one of them.
static func _inside_any(node: Node, nodes: Array) -> bool:
	for other: Node in nodes:
		if other == node or other.is_ancestor_of(node):
			return true
	return false


static func _record_dissolve_undo(undo_redo: Object, compound: Node, children: Array) -> void:
	var parent := compound.get_parent()
	add_undo_method(undo_redo, parent, &"add_child", [compound, true])
	undo_redo.add_undo_property(compound, &"owner", compound.owner)
	for child: Node in children:
		add_undo_method(undo_redo, child, &"reparent", [compound, true])
	undo_redo.add_undo_reference(compound)


static func _record_dissolve_do(undo_redo: Object, compound: Node, children: Array) -> void:
	var parent := compound.get_parent()
	var index := compound.get_index()
	for i in children.size():
		add_do_method(undo_redo, children[i], &"reparent", [parent, true])
		add_do_method(undo_redo, parent, &"move_child", [children[i], index + i])
	undo_redo.add_do_property(compound, &"owner", null)
	add_do_method(undo_redo, parent, &"remove_child", [compound])


static func _record_new_compound_do(undo_redo: Object, compound: Node, source: Node, scene_owner: Node) -> void:
	# Inserted right after the source, which then moves into it: the
	# compound takes the source's index and no other index changes.
	add_do_method(undo_redo, source, &"add_sibling", [compound, true])
	undo_redo.add_do_property(compound, &"owner", scene_owner)
	add_do_method(undo_redo, source, &"reparent", [compound, true])
	undo_redo.add_do_reference(compound)


static func _record_new_compound_undo(undo_redo: Object, compound: Node, source: Node) -> void:
	var parent := source.get_parent()
	add_undo_method(undo_redo, source, &"reparent", [parent, true])
	add_undo_method(undo_redo, parent, &"move_child", [source, source.get_index()])
	undo_redo.add_undo_property(compound, &"owner", null)
	add_undo_method(undo_redo, parent, &"remove_child", [compound])


## Adds a baked node under parent, removes the removed brushes and hides
## the hidden ones as one undoable action (Bake to Mesh).
static func bake_nodes(undo_redo: Object, action_name: String, parent: Node, baked: Node, removed: Array, hidden: Array, scene_owner: Node) -> void:
	undo_redo.create_action(action_name)
	_record_add(undo_redo, [parent], [baked], scene_owner)
	_record_remove(undo_redo, removed)
	for brush: TFBrush in hidden:
		add_do_method(undo_redo, brush, &"set_editor_hidden", [true])
		add_undo_method(undo_redo, brush, &"set_editor_hidden", [brush.is_editor_hidden()])
	undo_redo.commit_action()


static func _record_add(undo_redo: Object, parents: Array, brushes: Array, scene_owner: Node) -> void:
	for i in brushes.size():
		add_do_method(undo_redo, parents[i], &"add_child", [brushes[i], true])
		undo_redo.add_do_property(brushes[i], &"owner", scene_owner)
		# Duplicated groups bring their members along.
		for child in descendants(brushes[i]):
			undo_redo.add_do_property(child, &"owner", scene_owner)
		undo_redo.add_do_reference(brushes[i])
		add_undo_method(undo_redo, parents[i], &"remove_child", [brushes[i]])


static func _record_remove(undo_redo: Object, brushes: Array) -> void:
	var ordered := brushes.duplicate()
	ordered.sort_custom(func(a: Node, b: Node) -> bool: return a.get_index() < b.get_index())
	for brush: Node in ordered:
		var parent := brush.get_parent()
		# Clear the owner first; re-adding a node with a stale owner warns.
		undo_redo.add_do_property(brush, &"owner", null)
		add_do_method(undo_redo, parent, &"remove_child", [brush])
		add_undo_method(undo_redo, parent, &"add_child", [brush, true])
		add_undo_method(undo_redo, parent, &"move_child", [brush, brush.get_index()])
		undo_redo.add_undo_property(brush, &"owner", brush.owner)
		for child in descendants(brush):
			undo_redo.add_undo_property(child, &"owner", child.owner)
		undo_redo.add_undo_reference(brush)


## Hides or shows brushes in the editor (TFBrush.set_editor_hidden) as one
## undoable action.
static func set_hidden(undo_redo: Object, action_name: String, brushes: Array, hidden: bool) -> void:
	undo_redo.create_action(action_name)
	for brush: TFBrush in brushes:
		add_do_method(undo_redo, brush, &"set_editor_hidden", [hidden])
		add_undo_method(undo_redo, brush, &"set_editor_hidden", [brush.is_editor_hidden()])
	undo_redo.commit_action()


## Moves nodes to new parents (keeping their global position) as one
## undoable action.
static func reparent_nodes(undo_redo: Object, action_name: String, nodes: Array, new_parents: Array) -> void:
	undo_redo.create_action(action_name)
	record_reparent(undo_redo, nodes, new_parents)
	undo_redo.commit_action()


## Records do/undo reparenting; undo restores the old parents and order.
static func record_reparent(undo_redo: Object, nodes: Array, new_parents: Array) -> void:
	for i in nodes.size():
		add_do_method(undo_redo, nodes[i], &"reparent", [new_parents[i], true])
	var ordered := nodes.duplicate()
	ordered.sort_custom(func(a: Node, b: Node) -> bool: return a.get_index() < b.get_index())
	for node: Node in ordered:
		add_undo_method(undo_redo, node, &"reparent", [node.get_parent(), true])
	for node: Node in ordered:
		add_undo_method(undo_redo, node.get_parent(), &"move_child", [node, node.get_index()])


## All descendants of a node (not internal children).
static func descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in node.get_children():
		result.append(child)
		result.append_array(descendants(child))
	return result


## Creates a detached copy of a brush (deep-copied faces, same position
## and mode).
static func duplicate_brush(brush: TFBrush) -> TFBrush:
	var copy := TFBrush.new()
	copy.name = brush.name
	copy.position = brush.position
	copy.mode = brush.mode
	copy.faces = copy_faces(brush.faces)
	if brush.has_meta(TFConst.META_OWN_FACES):
		copy.set_meta(TFConst.META_OWN_FACES, true)
	if brush.has_meta(TFConst.META_SHAPE):
		copy.set_meta(TFConst.META_SHAPE, brush.get_meta(TFConst.META_SHAPE).duplicate())
	return copy


## Plain UndoRedo takes Callables, EditorUndoRedoManager takes object + method.
static func add_do_method(undo_redo: Object, target: Object, method: StringName, args: Array) -> void:
	if undo_redo is UndoRedo:
		undo_redo.add_do_method(Callable(target, method).bindv(args))
	else:
		undo_redo.callv(&"add_do_method", [target, method] + args)


static func add_undo_method(undo_redo: Object, target: Object, method: StringName, args: Array) -> void:
	if undo_redo is UndoRedo:
		undo_redo.add_undo_method(Callable(target, method).bindv(args))
	else:
		undo_redo.callv(&"add_undo_method", [target, method] + args)


static func copy_faces(source: Array) -> Array[TFFace]:
	var copies: Array[TFFace] = []
	for face in source:
		copies.append(face.copy() if face != null else null)
	return copies
