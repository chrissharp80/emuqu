import SwiftUI

// MARK: - SavedRoutesPage
//
// Settings → My Routes. Lists every route the user has explicitly saved
// from a workout. Renaming and deleting both happen inline; there's no
// editor for the polyline itself (the path comes from a recorded
// workout — to "edit" a route you re-walk it and re-save).
//
// Empty state explains the feature so users who haven't saved anything
// yet know how to use it.
struct SavedRoutesPage: View {
    @Environment(\.dependencies) var dependencies
    private var store: SavedRouteStore { dependencies.location.savedRouteStore }
    @State private var renamingRoute: SavedRoute?
    @State private var renameText: String = ""

    var body: some View {
        Group {
            if store.routes.isEmpty {
                emptyState
            } else {
                routeList
            }
        }
        .navigationTitle(String(localized: "My Routes", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename route", isPresented: Binding(
            get: { renamingRoute != nil },
            set: { if !$0 { renamingRoute = nil } }
        )) {
            renameDialogActions
        }
    }

    @ViewBuilder
    private var renameDialogActions: some View {
        TextField("Route name", text: $renameText)
        Button(String(localized: "Save", bundle: LanguageManager.appBundle)) {
            commitRename()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) { renamingRoute = nil }
    }

    private func commitRename() {
        if let r = renamingRoute {
            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                store.rename(id: r.id, to: trimmed)
            }
        }
        renamingRoute = nil
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "map.fill")
                .scaledFont(size: 48)
                .foregroundStyle(AppTheme.terracotta.opacity(0.6))
            Text(String(localized: "No saved routes yet", bundle: LanguageManager.appBundle))
                .font(.headline)
            Text(String(localized: "After a walk, run, or ride, tap \"Add to my route library\" on the workout summary. The coach will then recognise the route on future workouts — same direction or reversed — and pre-warn you about climbs ahead.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var routeList: some View {
        List {
            ForEach(store.routes) { route in
                swipeableRouteRow(route)
            }
        }
    }

    private func swipeableRouteRow(_ route: SavedRoute) -> some View {
        routeRow(route)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                swipeActions(for: route)
            }
    }

    @ViewBuilder
    private func swipeActions(for route: SavedRoute) -> some View {
        Button(role: .destructive) {
            store.remove(id: route.id)
        } label: {
            Label(String(localized: "Delete", bundle: LanguageManager.appBundle), systemImage: "trash")
        }
        Button {
            renamingRoute = route
            renameText = route.name
        } label: {
            Label(String(localized: "Rename", bundle: LanguageManager.appBundle), systemImage: "pencil")
        }
        .tint(.blue)
    }

    /// Route through the canonical units formatters so
    /// distance/elevation stay consistent with the rest of the app (and honour
    /// .auto locale resolution in one place).
    private func routeRow(_ route: SavedRoute) -> some View {
        let units = UnitsPreferenceStore.current.resolved
        let dist = units.formatDistance(meters: route.totalDistanceMeters)
        let ascent = "↑\(units.formatElevation(meters: route.totalAscentMeters))"
        return VStack(alignment: .leading, spacing: 4) {
            routeRowHeader(route)
            Text(verbatim: "\(dist) · \(ascent) · " + String(localized: "\(route.climbCount) climbs", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func routeRowHeader(_ route: SavedRoute) -> some View {
        HStack {
            Image(systemName: route.sport.icon)
                .foregroundStyle(AppTheme.terracotta)
            Text(route.name)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(route.createdAt, style: .date)
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }
}
