//! Scene I/O facade for the editor.
//!
//! This module keeps the stable import/export API surface used by editor panels while delegating
//! implementation to smaller submodules:
//! - scene_import_export.zig: serialization and ECS import/export
//! - scene_async_loading.zig: async model loading and instantiation
const scene_import_export = @import("scene_import_export.zig");
const scene_async_loading = @import("scene_async_loading.zig");

pub const import_scene_graph = scene_import_export.import_scene_graph;
pub const save_scene = scene_import_export.save_scene;
pub const load_scene = scene_import_export.load_scene;
pub const refresh_available_scenes = scene_import_export.refresh_available_scenes;
pub const remove_model_entities_and_rebase = scene_import_export.remove_model_entities_and_rebase;

pub const load_model_to_entity = scene_async_loading.load_model_to_entity;
pub const instantiate_model = scene_async_loading.instantiate_model;
pub const cancel_loading_tasks = scene_async_loading.cancel_loading_tasks;

