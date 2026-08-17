import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import '../connectors/data_source.dart';
import '../domain/workspace_tab.dart';

class WorkspaceState {
  const WorkspaceState({this.tabs = const [], this.activeTabId});
  final List<WorkspaceTab> tabs;
  final String? activeTabId;

  WorkspaceTab? get activeTab => tabs.cast<WorkspaceTab?>().firstWhere(
    (t) => t?.id == activeTabId,
    orElse: () => null,
  );

  WorkspaceState copyWith({List<WorkspaceTab>? tabs, String? activeTabId}) =>
      WorkspaceState(
        tabs: tabs ?? this.tabs,
        activeTabId: activeTabId ?? this.activeTabId,
      );
}

class WorkspaceNotifier extends StateNotifier<WorkspaceState> {
  WorkspaceNotifier() : super(const WorkspaceState());

  static const _uuid = Uuid();

  /// Opens (or re-activates) a browse tab.
  ///
  /// A null [container] is the level *above* one: the buckets of an object
  /// store, listed in the pane rather than only in the rail. That is what makes
  /// them reachable with the rail collapsed.
  String openBrowseTab(String connectionId, ContainerRef? container) {
    final existing = state.tabs.cast<WorkspaceTab?>().firstWhere(
      (t) =>
          t?.connectionId == connectionId &&
          t?.view == WorkspaceView.browse &&
          t?.container?.name == container?.name,
      orElse: () => null,
    );
    if (existing != null) {
      state = state.copyWith(activeTabId: existing.id);
      return existing.id;
    }
    final tab = WorkspaceTab(
      id: _uuid.v4(),
      connectionId: connectionId,
      view: WorkspaceView.browse,
      container: container,
    );
    state = state.copyWith(tabs: [...state.tabs, tab], activeTabId: tab.id);
    return tab.id;
  }

  String openQueryTab(String connectionId) {
    final tab = WorkspaceTab(
      id: _uuid.v4(),
      connectionId: connectionId,
      view: WorkspaceView.query,
    );
    state = state.copyWith(tabs: [...state.tabs, tab], activeTabId: tab.id);
    return tab.id;
  }

  /// Opens (or re-activates) the vector-space view of one collection.
  ///
  /// Deduplicated the way [openBrowseTab] is: a vector space is expensive to
  /// open — a few thousand vectors read and projected — and two tabs on the
  /// same collection would pay for it twice to show the same picture.
  String openVectorTab(String connectionId, ContainerRef container) {
    final existing = state.tabs.cast<WorkspaceTab?>().firstWhere(
      (t) =>
          t?.connectionId == connectionId &&
          t?.view == WorkspaceView.vectors &&
          t?.container?.name == container.name,
      orElse: () => null,
    );
    if (existing != null) {
      state = state.copyWith(activeTabId: existing.id);
      return existing.id;
    }
    final tab = WorkspaceTab(
      id: _uuid.v4(),
      connectionId: connectionId,
      view: WorkspaceView.vectors,
      container: container,
    );
    state = state.copyWith(tabs: [...state.tabs, tab], activeTabId: tab.id);
    return tab.id;
  }

  String openSchemaTab(String connectionId, ContainerRef container) {
    final tab = WorkspaceTab(
      id: _uuid.v4(),
      connectionId: connectionId,
      view: WorkspaceView.schema,
      container: container,
    );
    state = state.copyWith(tabs: [...state.tabs, tab], activeTabId: tab.id);
    return tab.id;
  }

  void closeTab(String tabId) {
    final remaining = state.tabs.where((t) => t.id != tabId).toList();
    final nextActive = state.activeTabId == tabId
        ? (remaining.isEmpty ? null : remaining.last.id)
        : state.activeTabId;
    state = WorkspaceState(tabs: remaining, activeTabId: nextActive);
  }

  void closeActiveTab() {
    final id = state.activeTabId;
    if (id != null) closeTab(id);
  }

  void closeAllTabs() {
    state = const WorkspaceState();
  }

  /// Closes every tab belonging to one connection, for when it is disconnected
  /// or deleted: a tab onto a source that is gone can only fail.
  void closeTabsFor(String connectionId) {
    final remaining = state.tabs
        .where((t) => t.connectionId != connectionId)
        .toList();
    final active = state.activeTabId;
    final keepsActive = remaining.any((t) => t.id == active);
    state = WorkspaceState(
      tabs: remaining,
      activeTabId: keepsActive
          ? active
          : (remaining.isEmpty ? null : remaining.last.id),
    );
  }

  void activate(String tabId) => state = state.copyWith(activeTabId: tabId);

  /// Switches what the tab shows without opening another one.
  ///
  /// The view is a property of the tab, not a tab of its own: the header's
  /// Browse / Query / Schema control switches between three views *of one
  /// object*, and a new tab per view would leave the strip full of duplicates
  /// of the same table.
  void setView(String tabId, WorkspaceView view) {
    final updated = state.tabs.map((t) {
      if (t.id != tabId) return t;
      t.view = view;
      return t;
    }).toList();
    state = state.copyWith(tabs: updated);
  }

  /// Points a tab at another object without opening a second one.
  ///
  /// What the file browser calls when the user walks into a bucket from the
  /// pane: the tab keeps its identity — and so its editor text and its place in
  /// the strip — while its title, the rail's highlight and the suggestions the
  /// query editor offers all follow where the user actually is.
  void setTabContainer(String tabId, ContainerRef? container) {
    final tab = state.tabs.cast<WorkspaceTab?>().firstWhere(
      (t) => t?.id == tabId,
      orElse: () => null,
    );
    if (tab == null || tab.container?.name == container?.name) return;
    final updated = state.tabs.map((t) {
      if (t.id != tabId) return t;
      t.container = container;
      return t;
    }).toList();
    state = state.copyWith(tabs: updated);
  }

  void updateQueryText(String tabId, String text) {
    final updated = state.tabs.map((t) {
      if (t.id != tabId) return t;
      t.queryText = text;
      return t;
    }).toList();
    state = state.copyWith(tabs: updated);
  }
}

final workspaceProvider =
    StateNotifierProvider<WorkspaceNotifier, WorkspaceState>(
      (ref) => WorkspaceNotifier(),
    );
