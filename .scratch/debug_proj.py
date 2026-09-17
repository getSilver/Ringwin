import sys, os
sys.path.insert(0, "python")
import control_plane_web as w
ROOT = os.getcwd()
p = w.ProjectionProvider(os.path.join(ROOT, ".scratch", "operator-ui-runtime"),
                         os.path.join(ROOT, ".scratch", "build", "control_projection_probe.exe"))
print("dir:", os.listdir(p.runtime_dir))
print(p.views())
