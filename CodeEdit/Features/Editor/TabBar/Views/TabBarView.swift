//
//  TabBarView.swift
//  CodeEdit
//
//  Created by Lukas Pistrol and Lingxi Li on 17.03.22.
//

import SwiftUI

// Disable the rule because the tab bar view is fairly complicated.
// It has the gesture implementation and its animations.
// I am now also disabling `file_length` rule because the dragging algorithm (with UX) is complex.
// swiftlint:disable file_length type_body_length
// - TODO: EditorTabView drop-outside event handler.
struct TabBarView: View {

    typealias TabID = CEWorkspaceFile.ID

    /// The height of tab bar.
    /// I am not making it a private variable because it may need to be used in outside views.
    static let height = 28.0

    @Environment(\.modifierKeys)
    var modifierKeys

    @Environment(\.splitEditor)
    var splitEditor

    @Environment(\.colorScheme)
    private var colorScheme

    @Environment(\.controlActiveState)
    private var activeState

    /// The workspace document.
    @EnvironmentObject private var workspace: WorkspaceDocument

    @EnvironmentObject private var editorManager: EditorManager

    @EnvironmentObject private var editor: Editor

    @AppSettings(\.general.tabBarStyle)
    var tabBarStyle

    /// The tab id of current dragging tab.
    ///
    /// It will be `nil` when there is no tab dragged currently.
    @State private var draggingTabId: TabID?

    @State private var onDragTabId: TabID?

    /// The start location of dragging.
    ///
    /// When there is no tab being dragged, it will be `nil`.
    /// - TODO: Check if I can use `value.startLocation` trustfully.
    @State private var draggingStartLocation: CGFloat?

    /// The last location of dragging.
    ///
    /// This is used to determine the dragging direction.
    /// - TODO: Check if I can use `value.translation` instead.
    @State private var draggingLastLocation: CGFloat?

    /// Current opened tabs.
    ///
    /// This is a copy of `workspace.selectionState.openedTabs`.
    /// I am making a copy of it because using state will hugely improve the dragging performance.
    /// Updating ObservedObject too often will generate lags.
    @State private var openedTabs: [TabID] = []

    /// A map of tab width.
    ///
    /// All width are measured dynamically (so it can also fit the Xcode tab bar style).
    /// This is used to be added on the offset of current dragging tab in order to make a smooth
    /// dragging experience.
    @State private var tabWidth: [TabID: CGFloat] = [:]

    /// A map of tab location (CGRect).
    ///
    /// All locations are measured dynamically.
    /// This is used to compute when we should swap two tabs based on current cursor location.
    @State private var tabLocations: [TabID: CGRect] = [:]

    /// A map of tab offsets.
    ///
    /// This is used to determine the tab offset of every tab (by their tab id) while dragging.
    @State private var tabOffsets: [TabID: CGFloat] = [:]

    /// The expected tab width in native tab bar style.
    ///
    /// This is computed by the total width of tab bar. It is updated automatically.
    @State private var expectedTabWidth: CGFloat = 0

    /// This state is used to detect if the mouse is hovering over tabs.
    /// If it is true, then we do not update the expected tab width immediately.
    @State private var isHoveringOverTabs: Bool = false

    /// This state is used to detect if the dragging type should be changed from DragGesture to OnDrag.
    /// It is basically switched when vertical displacement is exceeding the threshold.
    @State private var shouldOnDrag: Bool = false

    /// Is current `onDrag` over tabs?
    ///
    /// When it is true, then the `onDrag` is over the tabs, then we leave the space for dragged tab.
    /// When it is false, then the dragging cursor is outside the tab bar, then we should shrink the space.
    ///
    /// - TODO: The change of this state is overall incorrect. Should move it into workspace state.
    @State private var isOnDragOverTabs: Bool = false

    /// The last location of `onDrag`.
    ///
    /// It can be used on reordering algorithm of `onDrag` (detecting when should we switch two tabs).
    @State private var onDragLastLocation: CGPoint?

    @State private var closeButtonGestureActive: Bool = false

    @State private var scrollOffset: CGFloat = 0

    @State private var scrollTrailingOffset: CGFloat? = 0

    /// Update the expected tab width when corresponding UI state is updated.
    ///
    /// This function will be called when the number of tabs or the parent size is changed.
    private func updateExpectedTabWidth(proxy: GeometryProxy) {
        expectedTabWidth = max(
            // Equally divided size of a native tab.
            (proxy.size.width + 1) / CGFloat(editor.tabs.count) + 1,
            // Min size of a native tab.
            CGFloat(140)
        )
    }

    // Disable the rule because this function is implementing the drag gesture and its animations.
    // It is fairly complicated, so ignore the function body length limitation for now.
    // swiftlint:disable function_body_length cyclomatic_complexity
    private func makeTabDragGesture(id: TabID) -> some Gesture {
        return DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged({ value in
                if closeButtonGestureActive {
                    return
                }

                if draggingTabId != id {
                    shouldOnDrag = false
                    draggingTabId = id
                    draggingStartLocation = value.startLocation.x
                    draggingLastLocation = value.location.x
                }
                // TODO: Enable this code snippet when re-enabling dragging-out behavior.
                // I disabled (1 == 0) this behavior for now as dragging-out behavior isn't allowed.
                if 1 == 0 && abs(value.location.y - value.startLocation.y) > TabBarView.height {
                    shouldOnDrag = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                        shouldOnDrag = false
                        draggingStartLocation = nil
                        draggingLastLocation = nil
                        draggingTabId = nil
                        withAnimation(.easeInOut(duration: 0.25)) {
                            // Clean the tab offsets.
                            tabOffsets = [:]
                        }
                    })
                    return
                }
                // Get the current cursor location.
                let currentLocation = value.location.x
                guard let startLocation = draggingStartLocation,
                      let currentIndex = openedTabs.firstIndex(of: id),
                      let currentTabWidth = tabWidth[id],
                      let lastLocation = draggingLastLocation
                else { return }
                let dragDifference = currentLocation - lastLocation
                let previousIndex = currentIndex > 0 ? currentIndex - 1 : nil
                let nextIndex = currentIndex < openedTabs.count - 1 ? currentIndex + 1 : nil
                tabOffsets[id] = currentLocation - startLocation
                // Interacting with the previous tab.
                if previousIndex != nil && dragDifference < 0 {
                    // Wrap `previousTabIndex` because it may be `nil`.
                    guard let previousTabIndex = previousIndex,
                          let previousTabLocation = tabLocations[openedTabs[previousTabIndex]],
                          let previousTabWidth = tabWidth[openedTabs[previousTabIndex]]
                    else { return }
                    if currentLocation < max(
                        previousTabLocation.maxX - previousTabWidth * 0.1,
                        previousTabLocation.minX + currentTabWidth * 0.9
                    ) {
                        let changing = previousTabWidth - 1 // One offset for overlapping divider.
                        draggingStartLocation! -= changing
                        withAnimation {
                            tabOffsets[id]! += changing
                            openedTabs.move(
                                fromOffsets: IndexSet(integer: previousTabIndex),
                                toOffset: currentIndex + 1
                            )
                        }
                        return
                    }
                }
                // Interacting with the next tab.
                if nextIndex != nil && dragDifference > 0 {
                    // Wrap `previousTabIndex` because it may be `nil`.
                    guard let nextTabIndex = nextIndex,
                          let nextTabLocation = tabLocations[openedTabs[nextTabIndex]],
                          let nextTabWidth = tabWidth[openedTabs[nextTabIndex]]
                    else { return }
                    if currentLocation > min(
                        nextTabLocation.minX + nextTabWidth * 0.1,
                        nextTabLocation.maxX - currentTabWidth * 0.9
                    ) {
                        let changing = nextTabWidth - 1 // One offset for overlapping divider.
                        draggingStartLocation! += changing
                        withAnimation {
                            tabOffsets[id]! -= changing
                            openedTabs.move(
                                fromOffsets: IndexSet(integer: nextTabIndex),
                                toOffset: currentIndex
                            )
                        }
                        return
                    }
                }
                // Only update the last dragging location when there is enough offset.
                if draggingLastLocation == nil || abs(value.location.x - draggingLastLocation!) >= 10 {
                    draggingLastLocation = value.location.x
                }
            })
            .onEnded({ _ in
                shouldOnDrag = false
                draggingStartLocation = nil
                draggingLastLocation = nil
                withAnimation(.easeInOut(duration: 0.25)) {
                    tabOffsets = [:]
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    draggingTabId = nil
                }
                // Sync the workspace's `openedTabs` 150ms after animation is finished.
                // In order to avoid the lag due to the update of workspace state.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                    if draggingStartLocation == nil {
                        editor.tabs = .init(openedTabs.compactMap { id in
                            editor.tabs.first { $0.id == id }
                        })
                        // workspace.reorderedTabs(openedTabs: openedTabs)
                        // TODO: Fix save state
                    }
                }
            })
    }
    // swiftlint:enable function_body_length cyclomatic_complexity

    private func makeTabItemGeometryReader(id: TabID) -> some View {
        GeometryReader { tabItemGeoReader in
            Rectangle()
                .foregroundColor(.clear)
                .onAppear {
                    tabWidth[id] = tabItemGeoReader.size.width
                    tabLocations[id] = tabItemGeoReader
                        .frame(in: .global)
                }
                .onChange(
                    of: tabItemGeoReader.frame(in: .global),
                    perform: { tabCGRect in
                        tabLocations[id] = tabCGRect
                    }
                )
                .onChange(
                    of: tabItemGeoReader.size.width,
                    perform: { newWidth in
                        tabWidth[id] = newWidth
                    }
                )
        }
    }

    /// Conditionally updates the `expectedTabWidth`.
    /// Called when the tab count changes or the temporary tab changes.
    /// - Parameter geometryProxy: The geometry proxy to calculate the new width using.
    private func updateForTabCountChange(geometryProxy: GeometryProxy) {
        openedTabs = editor.tabs.map(\.id)

        // Only update the expected width when user is not hovering over tabs.
        // This should give users a better experience on closing multiple tabs continuously.
        if !isHoveringOverTabs {
            withAnimation(.easeOut(duration: 0.15)) {
                updateExpectedTabWidth(proxy: geometryProxy)
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Tab bar navigation control.
            leadingAccessories
                .background(.clear)
                .overlay(alignment: .trailing) {
                    if tabBarStyle == .xcode {
                        TabBarShadow(
                            width: colorScheme == .dark ? 5 : 7,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .offset(x: colorScheme == .dark ? 5 : 7)
                        .opacity(scrollOffset >= 0 ? 0 : 1)
                    }
                }
                .zIndex(1)
            // Tab bar items.
            GeometryReader { geometryProxy in
                TrackableScrollView(
                    .horizontal,
                    showIndicators: false,
                    contentOffset: $scrollOffset,
                    contentTrailingOffset: $scrollTrailingOffset
                ) {
                    ScrollViewReader { scrollReader in
                        HStack(
                            alignment: .center,
                            spacing: -1 // Negative spacing for overlapping the divider.
                        ) {
                            ForEach(Array(openedTabs.enumerated()), id: \.element) { index, id in
                                if let item = editor.tabs.first(where: { $0.id == id }) {
                                    EditorTabView(
                                        expectedWidth: expectedTabWidth,
                                        item: item,
                                        index: index,
                                        draggingTabId: draggingTabId,
                                        onDragTabId: onDragTabId,
                                        closeButtonGestureActive: $closeButtonGestureActive
                                    )
                                    .transition(
                                        .asymmetric(
                                            insertion: .offset(x: -14).combined(with: .opacity),
                                            removal: .opacity
                                        )
                                    )
                                    .frame(height: TabBarView.height)
                                    .background(makeTabItemGeometryReader(id: id))
                                    .offset(x: tabOffsets[id] ?? 0, y: 0)
                                    .simultaneousGesture(
                                        makeTabDragGesture(id: id),
                                        including: shouldOnDrag ? .subviews : .all
                                    )
                                    // TODO: Detect the onDrag outside of tab bar.
                                    // Detect the drop action of each tab.
                                    .onDrop(
                                        of: [.utf8PlainText], // TODO: Make a unique type for it.
                                        delegate: EditorTabOnDropDelegate(
                                            currentTabId: id,
                                            openedTabs: $openedTabs,
                                            onDragTabId: $onDragTabId,
                                            onDragLastLocation: $onDragLastLocation,
                                            isOnDragOverTabs: $isOnDragOverTabs,
                                            tabWidth: $tabWidth
                                        )
                                    )
                                }
                            }
                        }
                        // This padding is to hide dividers at two ends under the accessory view divider.
                        .padding(.horizontal, tabBarStyle == .native ? -1 : 0)
                        .onAppear {
                            openedTabs = editor.tabs.map(\.id)
                            // On view appeared, compute the initial expected width for tabs.
                            updateExpectedTabWidth(proxy: geometryProxy)
                            // On first tab appeared, jump to the corresponding position.
                            scrollReader.scrollTo(editor.selectedTab)
                        }
                        .onChange(of: editor.tabs) { [tabs = editor.tabs] newValue in
                            if tabs.count == newValue.count {
                                updateForTabCountChange(geometryProxy: geometryProxy)
                            } else {
                                withAnimation(
                                    .easeOut(duration: tabBarStyle == .native ? 0.15 : 0.20)
                                ) {
                                    updateForTabCountChange(geometryProxy: geometryProxy)
                                }
                            }
                            Task {
                                try? await Task.sleep(for: .milliseconds(300))
                                withAnimation {
                                    scrollReader.scrollTo(editor.selectedTab?.id)
                                }
                            }
                        }
                        // When selected tab is changed, scroll to it if possible.
                        .onChange(of: editor.selectedTab) { newValue in
                            withAnimation {
                                scrollReader.scrollTo(newValue?.id)
                            }
                        }

                        // When window size changes, re-compute the expected tab width.
                        .onChange(of: geometryProxy.size.width) { _ in
                            updateExpectedTabWidth(proxy: geometryProxy)
                            withAnimation {
                                scrollReader.scrollTo(editor.selectedTab?.id)
                            }
                        }
                        // When user is not hovering anymore, re-compute the expected tab width immediately.
                        .onHover { isHovering in
                            isHoveringOverTabs = isHovering
                            if !isHovering {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    updateExpectedTabWidth(proxy: geometryProxy)
                                }
                            }
                        }
                        .frame(height: TabBarView.height)
                    }

                    // To fill up the parent space of tab bar.
                    .frame(maxWidth: .infinity)
                    .background {
                        if tabBarStyle == .native {
                            TabBarNativeInactiveBackground()
                        }
                    }
                }
                .background {
                    if tabBarStyle == .native {
                        TabBarAccessoryNativeBackground(dividerAt: .none)
                    }
                }
            }
            // Tab bar tools (e.g. split view).
            trailingAccessories
                .overlay(alignment: .leading) {
                    if tabBarStyle == .xcode {
                        TabBarShadow(
                            width: colorScheme == .dark ? 5 : 7,
                            startPoint: .trailing,
                            endPoint: .leading
                        )
                        .offset(x: colorScheme == .dark ? -5 : -7)
                        .opacity((scrollTrailingOffset ?? 0) <= 0 ? 0 : 1)
                    }
                }
                .zIndex(1)
        }
        .frame(height: TabBarView.height)
        .overlay(alignment: .top) {
            // When tab bar style is `xcode`, we put the top divider as an overlay.
            if tabBarStyle == .xcode {
                TabBarTopDivider()
            }
        }
        .background {
            if tabBarStyle == .native {
                TabBarNativeMaterial()
                    .edgesIgnoringSafeArea(.top)
            } else {
                EffectView(.headerView)
            }
        }
        .padding(.leading, -1)
    }

    // MARK: Accessories

    private var leadingAccessories: some View {
        HStack(spacing: 0) {
            if let otherGroup = editorManager.editorLayout.findSomeEditor(except: editor) {
                TabBarAccessoryIcon(
                    icon: .init(systemName: "multiply"),
                    action: { [weak editor] in
                        editor?.close()
                        if editorManager.activeEditor == editor {
                            editorManager.activeEditorHistory.removeAll { $0() == nil || $0() == editor }
                            if editorManager.activeEditorHistory.isEmpty {
                                editorManager.activeEditor = otherGroup
                            } else {
                                editorManager.activeEditor = editorManager.activeEditorHistory.removeFirst()()!
                            }
                        }
                        editorManager.flatten()
                    }
                )
                .help("Close this Editor")
                .disabled(editorManager.isFocusingActiveEditor)
                .opacity(editorManager.isFocusingActiveEditor ? 0.5 : 1)

                TabBarAccessoryIcon(
                    icon: .init(
                        systemName: editorManager.isFocusingActiveEditor
                        ? "arrow.down.forward.and.arrow.up.backward"
                        : "arrow.up.left.and.arrow.down.right"
                    ),
                    isActive: editorManager.isFocusingActiveEditor,
                    action: {
                        if !editorManager.isFocusingActiveEditor {
                            editorManager.activeEditor = editor
                        }
                        editorManager.isFocusingActiveEditor.toggle()
                    }
                )
                .help(
                    editorManager.isFocusingActiveEditor
                      ? "Unfocus this Editor"
                      : "Focus this Editor"
                )

                Divider()
                    .frame(height: 10)
                    .padding(.horizontal, 4)
            }

            Group {
                Menu {
                    ForEach(
                        Array(editor.history.dropFirst(editor.historyOffset+1).enumerated()),
                        id: \.offset
                    ) { index, tab in
                        Button {
                            editorManager.activeEditor = editor
                            editor.historyOffset += index + 1
                        } label: {
                            HStack {
                                tab.icon
                                Text(tab.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .controlSize(.regular)
                        .opacity(
                            editor.historyOffset == editor.history.count-1 || editor.history.isEmpty
                            ? 0.5 : 1.0
                        )
                } primaryAction: {
                    editorManager.activeEditor = editor
                    editor.goBackInHistory()
                }
                .disabled(editor.historyOffset == editor.history.count-1 || editor.history.isEmpty)
                .help("Navigate back")

                Menu {
                    ForEach(
                        Array(editor.history.prefix(editor.historyOffset).reversed().enumerated()),
                        id: \.offset
                    ) { index, tab in
                        Button {
                            editorManager.activeEditor = editor
                            editor.historyOffset -= index + 1
                        } label: {
                            HStack {
                                tab.icon
                                Text(tab.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .controlSize(.regular)
                        .opacity(editor.historyOffset == 0 ? 0.5 : 1.0)
                } primaryAction: {
                    editorManager.activeEditor = editor
                    editor.goForwardInHistory()
                }
                .disabled(editor.historyOffset == 0)
                .help("Navigate forward")
            }
            .controlSize(.small)
            .font(TabBarAccessoryIcon.iconFont)
            .frame(height: TabBarView.height - 2)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .foregroundColor(.secondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .opacity(activeState != .inactive ? 1.0 : 0.5)
        .frame(maxHeight: .infinity) // Fill out vertical spaces.
        .background {
            if tabBarStyle == .native {
                TabBarAccessoryNativeBackground(dividerAt: .trailing)
            }
        }
    }

    private var trailingAccessories: some View {
        HStack(spacing: 0) {
            splitviewButton
        }
        .padding(.horizontal, 7)
        .opacity(activeState != .inactive ? 1.0 : 0.5)
        .frame(maxHeight: .infinity) // Fill out vertical spaces.
        .background {
            if tabBarStyle == .native {
                TabBarAccessoryNativeBackground(dividerAt: .leading)
            }
        }
    }

    var splitviewButton: some View {
        Group {
            switch (editor.parent?.axis, modifierKeys.contains(.option)) {
            case (.horizontal, true), (.vertical, false):
                Button {
                    split(edge: .bottom)
                } label: {
                    Image(systemName: "square.split.1x2")
                }
                .help("Split Vertically")

            case (.vertical, true), (.horizontal, false):
                Button {
                    split(edge: .trailing)
                } label: {
                    Image(systemName: "square.split.2x1")
                }
                .help("Split Horizontally")

            default:
                EmptyView()
            }
        }
        .buttonStyle(.icon)
        .disabled(editorManager.isFocusingActiveEditor)
        .opacity(editorManager.isFocusingActiveEditor ? 0.5 : 1)
    }

    func split(edge: Edge) {
        let newEditor: Editor
        if let tab = editor.selectedTab {
            newEditor = .init(files: [tab])
        } else {
            newEditor = .init()
        }
        splitEditor(edge, newEditor)
        editorManager.activeEditor = newEditor
    }

    private struct EditorTabOnDropDelegate: DropDelegate {
        private let currentTabId: TabID
        @Binding private var openedTabs: [TabID]
        @Binding private var onDragTabId: TabID?
        @Binding private var onDragLastLocation: CGPoint?
        @Binding private var isOnDragOverTabs: Bool
        @Binding private var tabWidth: [TabID: CGFloat]

        public init(
            currentTabId: TabID,
            openedTabs: Binding<[TabID]>,
            onDragTabId: Binding<TabID?>,
            onDragLastLocation: Binding<CGPoint?>,
            isOnDragOverTabs: Binding<Bool>,
            tabWidth: Binding<[TabID: CGFloat]>
        ) {
            self.currentTabId = currentTabId
            self._openedTabs = openedTabs
            self._onDragTabId = onDragTabId
            self._onDragLastLocation = onDragLastLocation
            self._isOnDragOverTabs = isOnDragOverTabs
            self._tabWidth = tabWidth
        }

        func dropEntered(info: DropInfo) {
            isOnDragOverTabs = true
            guard let onDragTabId,
                  currentTabId != onDragTabId,
                  let from = openedTabs.firstIndex(of: onDragTabId),
                  let toIndex = openedTabs.firstIndex(of: currentTabId)
            else { return }
            if openedTabs[toIndex] != onDragTabId {
                withAnimation {
                    openedTabs.move(
                        fromOffsets: IndexSet(integer: from),
                        toOffset: toIndex > from ? toIndex + 1 : toIndex
                    )
                }
            }
        }

        func dropExited(info: DropInfo) {
            // Do nothing.
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            isOnDragOverTabs = false
            onDragTabId = nil
            onDragLastLocation = nil
            return true
        }
    }
}
// swiftlint:enable type_body_length