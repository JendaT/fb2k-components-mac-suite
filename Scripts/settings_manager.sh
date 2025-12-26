#!/bin/bash
#
# foobar2000 Settings Manager
#
# Manages settings backup/restore for clean install testing of components.
#
# Usage:
#   ./settings_manager.sh backup [name]    - Backup current settings
#   ./settings_manager.sh clean            - Remove developed components (clean install test)
#   ./settings_manager.sh restore [name]   - Restore settings from backup
#   ./settings_manager.sh list             - List available backups
#
# The 'clean' command removes our developed components and their config files,
# simulating a fresh install for testing purposes.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# foobar2000 settings locations
FB2K_SETTINGS="$HOME/Library/foobar2000-v2"
FB2K_APP_SUPPORT="$HOME/Library/Application Support/foobar2000"

# Backup location
BACKUP_DIR="$PROJECT_ROOT/.settings_backups"

# Our developed components
OUR_COMPONENTS=(
    "foo_simplaylist"
    "foo_plorg"
    "foo_wave_seekbar"
    "foo_scrobble"
)

# Component-specific config files in settings folder
COMPONENT_CONFIGS=(
    "foo_plorg.yaml"
)

# Files to exclude from backup (too large, not needed for component testing)
EXCLUDE_FROM_BACKUP=(
    "metadb.sqlite"
    "metadb.sqlite-shm"
    "metadb.sqlite-wal"
    "library-v2.0"
    "ImageCache"
    "library-error-log.txt"
    "library-error-log-previous.txt"
)

show_help() {
    echo "foobar2000 Settings Manager"
    echo ""
    echo "Usage:"
    echo "  $0 backup [name]    - Backup current settings (default name: timestamp)"
    echo "  $0 clean            - Remove developed components for clean install test"
    echo "  $0 restore [name]   - Restore settings from backup (default: latest)"
    echo "  $0 list             - List available backups"
    echo ""
    echo "Examples:"
    echo "  $0 backup before-release    # Create named backup"
    echo "  $0 clean                    # Remove our components"
    echo "  $0 restore                  # Restore latest backup"
    echo "  $0 restore before-release   # Restore specific backup"
}

check_fb2k_not_running() {
    if pgrep -x "foobar2000" > /dev/null; then
        echo "Error: foobar2000 is running. Please quit it first."
        exit 1
    fi
}

do_backup() {
    local name="${1:-$(date +%Y%m%d_%H%M%S)}"
    local backup_path="$BACKUP_DIR/$name"

    if [ -d "$backup_path" ]; then
        echo "Error: Backup '$name' already exists"
        exit 1
    fi

    echo "Creating backup: $name"
    mkdir -p "$backup_path"

    # Build rsync exclude list
    local excludes=""
    for item in "${EXCLUDE_FROM_BACKUP[@]}"; do
        excludes="$excludes --exclude=$item"
    done

    # Backup main settings (excluding large files)
    if [ -d "$FB2K_SETTINGS" ]; then
        echo "  Backing up $FB2K_SETTINGS..."
        rsync -a $excludes "$FB2K_SETTINGS/" "$backup_path/foobar2000-v2/"
    fi

    # Backup Application Support components
    if [ -d "$FB2K_APP_SUPPORT" ]; then
        echo "  Backing up $FB2K_APP_SUPPORT..."
        rsync -a "$FB2K_APP_SUPPORT/" "$backup_path/Application Support-foobar2000/"
    fi

    # Save backup metadata
    echo "timestamp=$(date -Iseconds)" > "$backup_path/.metadata"
    echo "components=${OUR_COMPONENTS[*]}" >> "$backup_path/.metadata"

    echo ""
    echo "Backup created: $backup_path"
    echo "  Size: $(du -sh "$backup_path" | cut -f1)"
    echo ""
    echo "Note: metadb.sqlite and library excluded (too large, not needed for component testing)"
}

do_clean() {
    check_fb2k_not_running

    echo "Preparing clean install test environment..."
    echo ""
    echo "This will remove the following components:"
    for comp in "${OUR_COMPONENTS[@]}"; do
        echo "  - $comp"
    done
    echo ""
    echo "And these config files:"
    for cfg in "${COMPONENT_CONFIGS[@]}"; do
        echo "  - $cfg"
    done
    echo ""

    # Remove components from user-components
    for comp in "${OUR_COMPONENTS[@]}"; do
        local comp_path="$FB2K_SETTINGS/user-components/$comp"
        if [ -d "$comp_path" ]; then
            echo "Removing: $comp_path"
            rm -rf "$comp_path"
        fi

        # Also check Application Support location
        local alt_path="$FB2K_APP_SUPPORT/user-components/$comp"
        if [ -d "$alt_path" ]; then
            echo "Removing: $alt_path"
            rm -rf "$alt_path"
        fi
    done

    # Remove component config files
    for cfg in "${COMPONENT_CONFIGS[@]}"; do
        local cfg_path="$FB2K_SETTINGS/$cfg"
        if [ -f "$cfg_path" ]; then
            echo "Removing: $cfg_path"
            rm -f "$cfg_path"
        fi
    done

    # Clear component entries from config.sqlite
    if [ -f "$FB2K_SETTINGS/config.sqlite" ]; then
        echo ""
        echo "Clearing component settings from config.sqlite..."
        for comp in "${OUR_COMPONENTS[@]}"; do
            # Remove config entries that start with component name
            sqlite3 "$FB2K_SETTINGS/config.sqlite" \
                "DELETE FROM config WHERE key LIKE '${comp//_/.}.%';" 2>/dev/null || true
            sqlite3 "$FB2K_SETTINGS/config.sqlite" \
                "DELETE FROM config WHERE key LIKE '${comp}.%';" 2>/dev/null || true
        done
    fi

    echo ""
    echo "Clean install environment ready."
    echo ""
    echo "To test components:"
    echo "  1. Run: ./Scripts/build_all.sh --install"
    echo "  2. Launch foobar2000 from CLI to verify component loading"
    echo "  3. Test functionality"
    echo "  4. Run: ./Scripts/settings_manager.sh restore"
}

do_restore() {
    check_fb2k_not_running

    local name="$1"
    local backup_path

    if [ -z "$name" ]; then
        # Find latest backup
        backup_path=$(ls -td "$BACKUP_DIR"/*/ 2>/dev/null | head -1)
        if [ -z "$backup_path" ]; then
            echo "Error: No backups found"
            exit 1
        fi
        backup_path="${backup_path%/}"
        name=$(basename "$backup_path")
    else
        backup_path="$BACKUP_DIR/$name"
    fi

    if [ ! -d "$backup_path" ]; then
        echo "Error: Backup '$name' not found"
        echo "Available backups:"
        do_list
        exit 1
    fi

    echo "Restoring from backup: $name"

    # Restore main settings
    if [ -d "$backup_path/foobar2000-v2" ]; then
        echo "  Restoring user-components..."
        if [ -d "$backup_path/foobar2000-v2/user-components" ]; then
            rsync -a "$backup_path/foobar2000-v2/user-components/" "$FB2K_SETTINGS/user-components/"
        fi

        # Restore component configs
        for cfg in "${COMPONENT_CONFIGS[@]}"; do
            if [ -f "$backup_path/foobar2000-v2/$cfg" ]; then
                echo "  Restoring $cfg..."
                cp "$backup_path/foobar2000-v2/$cfg" "$FB2K_SETTINGS/$cfg"
            fi
        done

        # Restore config.sqlite (contains component settings)
        if [ -f "$backup_path/foobar2000-v2/config.sqlite" ]; then
            echo "  Restoring config.sqlite..."
            cp "$backup_path/foobar2000-v2/config.sqlite" "$FB2K_SETTINGS/config.sqlite"
        fi
    fi

    # Restore Application Support
    if [ -d "$backup_path/Application Support-foobar2000" ]; then
        echo "  Restoring Application Support..."
        rsync -a "$backup_path/Application Support-foobar2000/" "$FB2K_APP_SUPPORT/"
    fi

    echo ""
    echo "Settings restored from: $name"
}

do_list() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo "No backups found"
        return
    fi

    echo "Available backups:"
    echo ""
    for backup in "$BACKUP_DIR"/*/; do
        if [ -d "$backup" ]; then
            local name=$(basename "$backup")
            local size=$(du -sh "$backup" | cut -f1)
            local timestamp=""
            if [ -f "$backup/.metadata" ]; then
                timestamp=$(grep "^timestamp=" "$backup/.metadata" | cut -d= -f2)
            fi
            printf "  %-25s %8s  %s\n" "$name" "$size" "$timestamp"
        fi
    done
}

# Main
case "${1:-help}" in
    backup)
        do_backup "$2"
        ;;
    clean)
        do_backup "pre_clean_$(date +%Y%m%d_%H%M%S)"
        do_clean
        ;;
    restore)
        do_restore "$2"
        ;;
    list)
        do_list
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
