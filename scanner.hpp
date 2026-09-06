#pragma once
#include <string>
#include <vector>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <sys/stat.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <dirent.h>
#include <unistd.h>
#include <algorithm>
#include <mach/mach.h>
#include <mach/mach_host.h>

namespace cleaner {

struct Location {
    std::string label;
    std::vector<std::string> paths;
};

inline bool pathExists(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0;
}

inline std::string expandHome(const std::string& p) {
    if (!p.empty() && p[0] == '~') {
        const char* home = getenv("HOME");
        if (home) return std::string(home) + p.substr(1);
    }
    return p;
}

// Recursively sums on-disk size (st_blocks) without following symlinks.
inline uint64_t dirSize(const std::string& path) {
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) return 0;
    if (S_ISLNK(st.st_mode)) return 0;
    if (!S_ISDIR(st.st_mode)) return (uint64_t)st.st_blocks * 512;

    uint64_t total = 0;
    DIR* d = opendir(path.c_str());
    if (!d) return 0;
    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        total += dirSize(path + "/" + name);
    }
    closedir(d);
    return total;
}

// Recursively deletes a single file or directory tree.
inline void removePath(const std::string& path) {
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) return; // already gone
    if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) {
        DIR* d = opendir(path.c_str());
        if (d) {
            struct dirent* entry;
            while ((entry = readdir(d)) != nullptr) {
                std::string name = entry->d_name;
                if (name == "." || name == "..") continue;
                removePath(path + "/" + name);
            }
            closedir(d);
        }
        rmdir(path.c_str());
    } else {
        unlink(path.c_str());
    }
}

// Empties a directory's contents, keeping the directory itself.
inline void clearDirContents(const std::string& path) {
    struct stat st;
    if (stat(path.c_str(), &st) != 0) return; // nothing to clear
    DIR* d = opendir(path.c_str());
    if (!d) return;
    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        removePath(path + "/" + name);
    }
    closedir(d);
}

inline uint64_t locationSize(const Location& loc) {
    uint64_t total = 0;
    for (auto& p : loc.paths) total += dirSize(p);
    return total;
}

inline void clearLocation(const Location& loc) {
    for (auto& p : loc.paths) clearDirContents(p);
}

// Chrome keeps its real cache (HTTP disk cache) under ~/Library/Caches, but
// several other pure-cache directories live inside the profile folder next
// to History/Cookies/IndexedDB. This walks every profile ("Default",
// "Profile 1", ...) and collects only the safe-to-empty ones.
inline std::vector<std::string> discoverChromeCachePaths() {
    std::vector<std::string> paths;
    std::string root = expandHome("~/Library/Application Support/Google/Chrome");
    if (!pathExists(root)) return paths;

    const char* topLevel[] = {
        "GrShaderCache", "ShaderCache", "GraphiteDawnCache",
        "GPUPersistentCache", "component_crx_cache", "extensions_crx_cache"
    };
    for (auto name : topLevel) {
        std::string p = root + "/" + name;
        if (pathExists(p)) paths.push_back(p);
    }

    DIR* d = opendir(root.c_str());
    if (!d) return paths;
    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        bool isProfile = (name == "Default" || name.rfind("Profile ", 0) == 0);
        if (!isProfile) continue;
        struct stat st;
        std::string profileDir = root + "/" + name;
        if (stat(profileDir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) continue;

        const char* sub[] = {
            "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
            "Service Worker/CacheStorage", "Service Worker/ScriptCache"
        };
        for (auto s : sub) {
            std::string p = profileDir + "/" + s;
            if (pathExists(p)) paths.push_back(p);
        }
    }
    closedir(d);
    return paths;
}

struct DiskUsage {
    uint64_t totalBytes = 0;
    uint64_t freeBytes = 0;
    uint64_t usedBytes = 0;
};

// Stats the volume backing the home directory (the real user-data volume on
// modern macOS, not the sealed read-only system volume that "/" reports).
inline DiskUsage getDiskUsage() {
    DiskUsage du;
    struct statfs s;
    std::string home = expandHome("~");
    if (statfs(home.c_str(), &s) == 0) {
        du.totalBytes = (uint64_t)s.f_blocks * (uint64_t)s.f_bsize;
        du.freeBytes  = (uint64_t)s.f_bavail * (uint64_t)s.f_bsize;
        du.usedBytes  = du.totalBytes > du.freeBytes ? du.totalBytes - du.freeBytes : 0;
    }
    return du;
}

struct RamUsage {
    uint64_t totalBytes = 0;
    uint64_t usedBytes = 0;
    uint64_t freeBytes = 0;
};

// Approximates Activity Monitor's "Memory Used": active + wired + compressed
// pages counted as used, free + inactive (reclaimable) counted as available.
inline RamUsage getRamUsage() {
    RamUsage ru;
    int64_t memsize = 0;
    size_t len = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &len, NULL, 0) == 0) {
        ru.totalBytes = (uint64_t)memsize;
    }

    vm_size_t pageSize = 4096;
    host_page_size(mach_host_self(), &pageSize);

    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t kr = host_statistics64(mach_host_self(), HOST_VM_INFO64,
                                          (host_info64_t)&vmStats, &count);
    if (kr == KERN_SUCCESS) {
        ru.usedBytes = (uint64_t)(vmStats.active_count + vmStats.wire_count +
                                   vmStats.compressor_page_count) * (uint64_t)pageSize;
        ru.freeBytes = (uint64_t)(vmStats.free_count + vmStats.inactive_count) * (uint64_t)pageSize;
    }
    return ru;
}

inline std::string humanSize(uint64_t bytes) {
    const char* units[] = {"B", "KB", "MB", "GB", "TB"};
    double size = (double)bytes;
    int unit = 0;
    while (size >= 1024.0 && unit < 4) { size /= 1024.0; unit++; }
    char buf[64];
    snprintf(buf, sizeof(buf), "%.1f %s", size, units[unit]);
    return std::string(buf);
}

struct BigItem {
    std::string path;
    uint64_t size = 0;
};

inline std::string shortenHome(const std::string& p) {
    const char* home = getenv("HOME");
    if (home) {
        std::string h(home);
        if (p.rfind(h, 0) == 0) return "~" + p.substr(h.size());
    }
    return p;
}

// Scans the top level of a handful of common bloat spots (Desktop, Downloads,
// Documents, dev project roots) and returns the N largest entries found,
// across all of them combined. These are real user data/projects, not
// caches, so they are surfaced for review rather than offered for deletion.
inline std::vector<BigItem> findBiggestItems(size_t topN) {
    std::vector<std::string> roots = {
        expandHome("~/Desktop"),
        expandHome("~/Downloads"),
        expandHome("~/Documents"),
        expandHome("~/development"),
        expandHome("~/dev"),
    };
    std::vector<BigItem> items;
    for (auto& root : roots) {
        if (!pathExists(root)) continue;
        DIR* d = opendir(root.c_str());
        if (!d) continue;
        struct dirent* entry;
        while ((entry = readdir(d)) != nullptr) {
            std::string name = entry->d_name;
            if (name == "." || name == "..") continue;
            if (!name.empty() && name[0] == '.') continue; // skip dotfiles/hidden
            std::string full = root + "/" + name;
            items.push_back({full, dirSize(full)});
        }
        closedir(d);
    }
    std::sort(items.begin(), items.end(), [](const BigItem& a, const BigItem& b) {
        return a.size > b.size;
    });
    if (items.size() > topN) items.resize(topN);
    return items;
}

// Locations that are always safe to empty: everything here is a cache or
// trash that the owning app/tool regenerates automatically.
inline std::vector<Location> safeLocations() {
    std::vector<Location> locs = {
        {"App & System Caches",  {expandHome("~/Library/Caches")}},
        {"Xcode DerivedData",    {expandHome("~/Library/Developer/Xcode/DerivedData")}},
        {"iOS Simulator Caches", {expandHome("~/Library/Developer/CoreSimulator/Caches")}},
        {"npm Cache",            {expandHome("~/.npm")}},
        {"Trash",                {expandHome("~/.Trash")}},
    };
    locs.push_back({"Chrome Browser Cache", discoverChromeCachePaths()});
    return locs;
}

} // namespace cleaner
