# A tree as text: every entry with its kind, mode and contents or link target,
# never following a link. Two trees copied faithfully print the same.
import os, stat, sys
root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(dirnames + filenames):
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        st = os.lstat(path)
        mode = format(stat.S_IMODE(st.st_mode), "o")
        if stat.S_ISLNK(st.st_mode):
            print(f"{rel} link -> {os.readlink(path)}")
        elif stat.S_ISDIR(st.st_mode):
            print(f"{rel} dir {mode}")
        else:
            print(f"{rel} file {mode} {open(path, 'rb').read()!r}")
