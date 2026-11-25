"""Dependency-graph regressions independent of a particular Homebrew installation."""
import importlib.util
from pathlib import Path
import sys
import plistlib
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "bundle-media-libraries.py"
SPEC = importlib.util.spec_from_file_location("media_bundle", SCRIPT)
bundle = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bundle
SPEC.loader.exec_module(bundle)


class MediaBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.file("app/Contents/MacOS/SeatSix")

    def file(self, name):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("original")
        return path

    def test_parse_spaces_weak_links_and_universal_duplicates(self):
        output = """/some binary (architecture arm64):
\t/a path/liba.dylib (compatibility version 1.0.0, current version 2.0.0, weak)
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 2.0.0)
/some binary (architecture x86_64):
\t/a path/liba.dylib (compatibility version 1.0.0, current version 2.0.0, weak)
"""
        self.assertEqual(bundle.parse_dependencies(output),
                         ["/a path/liba.dylib", "/usr/lib/libSystem.B.dylib"])

    def test_parse_only_rpath_load_commands(self):
        output = """          cmd LC_RPATH
      cmdsize 64
         path @loader_path/with spaces (offset 12)
Load command 3
          cmd LC_LOAD_DYLIB
         name /unrelated (offset 24)
Load command 4
          cmd LC_RPATH
         path /usr/lib/swift (offset 12)
"""
        self.assertEqual(bundle.parse_rpaths(output), ["@loader_path/with spaces", "/usr/lib/swift"])

    def test_minimum_macos_handles_modern_legacy_and_multiple_slices(self):
        output = """          cmd LC_BUILD_VERSION
 platform 1
    minos 27.0
      sdk 27.1
   ntools 1
     tool 3
  version 27037.1
          cmd LC_VERSION_MIN_MACOSX
  version 14.0
      sdk 26.0
"""
        self.assertEqual(bundle.parse_minimum_macos(output), "27.0")
        self.assertIsNone(bundle.parse_minimum_macos(""))

    def test_bundle_minimum_version_is_numeric_and_never_lowered(self):
        self.assertGreater(bundle.version_key("14.0"), bundle.version_key("10.15"))
        self.assertEqual(bundle.version_key("27"), bundle.version_key("27.0.0"))
        path = self.root / "Info.plist"
        with path.open("wb") as file:
            plistlib.dump({"LSMinimumSystemVersion": "14.0", "CFBundleName": "SeatSix"}, file)
        self.assertEqual(bundle.apply_minimum_macos(path, "27.0"), "27.0")
        self.assertEqual(bundle.apply_minimum_macos(path, "10.15"), "27.0")
        with path.open("rb") as file:
            info = plistlib.load(file)
        self.assertEqual(info["CFBundleName"], "SeatSix")

    def test_shared_cache_system_dependencies_do_not_need_files(self):
        path = bundle.resolve_dependency("@rpath/libswiftMissing.dylib", self.app,
                                         self.app, ("/usr/lib/swift",))
        self.assertEqual(str(path), "/usr/lib/swift/libswiftMissing.dylib")
        self.assertFalse(bundle.is_system("/usr/libevil/libfoo.dylib"))
        self.assertFalse(bundle.is_system("/usr/lib/../../tmp/libfoo.dylib"))

    def test_transitive_cycle_and_symlinks_are_copied_once(self):
        first, second = self.file("brew/liba.1.dylib"), self.file("brew/libb.2.dylib")
        alias = self.root / "brew/liba.dylib"
        alias.symlink_to(first.name)
        infos = {
            self.app: bundle.Metadata((str(alias),), ()),
            first: bundle.Metadata(("@loader_path/libb.2.dylib",), ()),
            second: bundle.Metadata((str(alias), "/usr/lib/libSystem.B.dylib"), ())
        }
        closure = bundle.collect_closure(self.app, infos.__getitem__)
        self.assertEqual(set(closure.libraries.values()), {first, second})
        self.assertEqual(first.read_text(), "original")

    def test_inherited_rpaths_resolve_at_owner_location(self):
        first, second = self.file("app/shared/liba.dylib"), self.file("app/shared/libb.dylib")
        infos = {
            self.app: bundle.Metadata(("@rpath/liba.dylib",), ("@executable_path/../../shared",)),
            first: bundle.Metadata(("@rpath/libb.dylib",), ()),
            second: bundle.Metadata((), ())
        }
        closure = bundle.collect_closure(self.app, infos.__getitem__)
        self.assertEqual(closure.edges[first]["@rpath/libb.dylib"], second)

    def test_unresolved_dependency_fails_instead_of_searching_global_path(self):
        with self.assertRaisesRegex(bundle.BundleError, "Unresolved dependency"):
            bundle.resolve_dependency("@rpath/libmissing.dylib", self.app, self.app, ())
        with self.assertRaisesRegex(bundle.BundleError, "Unresolved dependency"):
            bundle.resolve_dependency("libmissing.dylib", self.app, self.app, ())

    def test_duplicate_basename_including_case_is_rejected(self):
        first, second = self.file("one/libx.dylib"), self.file("two/LIBX.dylib")
        infos = {self.app: bundle.Metadata((str(first), str(second)), ()),
                 first: bundle.Metadata((), ()), second: bundle.Metadata((), ())}
        with self.assertRaisesRegex(bundle.BundleError, "basename collision"):
            bundle.collect_closure(self.app, infos.__getitem__)

    def test_conflicting_loader_chains_fail(self):
        first, second = self.file("one/liba.dylib"), self.file("two/libb.dylib")
        shared = self.file("shared/libc.dylib")
        x1, x2 = self.file("one/libx.dylib"), self.file("two/libx.dylib")
        infos = {
            self.app: bundle.Metadata((str(first), str(second)), ()),
            first: bundle.Metadata((str(shared),), ("@loader_path",)),
            second: bundle.Metadata((str(shared),), ("@loader_path",)),
            shared: bundle.Metadata(("@rpath/libx.dylib",), ()),
            x1: bundle.Metadata((), ()), x2: bundle.Metadata((), ())
        }
        with self.assertRaisesRegex(bundle.BundleError, "Ambiguous inherited"):
            bundle.collect_closure(self.app, infos.__getitem__)

    def test_verification_rejects_external_and_traversal_references(self):
        frameworks = self.app.parent.parent / "Frameworks"
        lib = self.file(str((frameworks / "libmpv.2.dylib").relative_to(self.root)))
        base = {self.app: bundle.Metadata(("@executable_path/../Frameworks/libmpv.2.dylib",), ()),
                lib: bundle.Metadata((), (), "@rpath/libmpv.2.dylib")}
        bundle.verify_relocated(self.app, frameworks, {lib.name}, base.__getitem__)
        for bad in ("/opt/homebrew/lib/libmpv.2.dylib", "@loader_path/../../outside/libmpv.2.dylib"):
            base[lib] = bundle.Metadata((bad,), (), "@rpath/libmpv.2.dylib")
            with self.assertRaises(bundle.BundleError):
                bundle.verify_relocated(self.app, frameworks, {lib.name}, base.__getitem__)

    def test_non_system_rpath_fails_verification(self):
        base = {self.app: bundle.Metadata((), ("/opt/homebrew/lib",))}
        with self.assertRaisesRegex(bundle.BundleError, "rpath remains"):
            bundle.verify_relocated(self.app, self.app.parent.parent / "Frameworks", set(), base.__getitem__)

    def test_provenance_reads_installed_version_and_rejects_foreign_library(self):
        self.assertEqual(bundle.installed_formula(Path("/opt/homebrew/Cellar/mpv/0.41.0_11/lib/libmpv.2.dylib")),
                         ("mpv", "0.41.0_11"))
        with self.assertRaisesRegex(bundle.BundleError, "provenance"):
            bundle.installed_formula(Path("/Applications/SomeApp.app/Contents/Frameworks/libmpv.dylib"))

    def test_universal_system_app_verifies_both_slices_and_rejects_private_paths(self):
        app = self.app.parents[2]
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "14.0"}))
        clean = bundle.Metadata(("/usr/lib/libSystem.B.dylib",), (), minimum_macos="14.0")
        with mock.patch.object(bundle, "run", return_value="arm64 x86_64"), \
                mock.patch.object(bundle, "metadata", return_value=clean) as read:
            bundle.verify_system_app(app)
            self.assertEqual([call.args[1] for call in read.call_args_list], ["arm64", "x86_64"])
            self.app.write_bytes(b"/Users/example/checkout/.build")
            with self.assertRaisesRegex(bundle.BundleError, "developer-machine"):
                bundle.verify_system_app(app)
        self.app.write_bytes(b"binary")
        for bad in (bundle.Metadata(("/opt/homebrew/lib/extra.dylib",), ()),
                    bundle.Metadata(clean.dependencies, ("@loader_path",)),
                    bundle.Metadata(clean.dependencies, (), minimum_macos="15.0")):
            with self.subTest(bad=bad), mock.patch.object(bundle, "run", return_value="arm64 x86_64"), \
                    mock.patch.object(bundle, "metadata", side_effect=[clean, bad]), \
                    self.assertRaises(bundle.BundleError):
                bundle.verify_system_app(app)
        with mock.patch.object(bundle, "run", return_value="arm64"), self.assertRaisesRegex(bundle.BundleError, "universal"):
            bundle.verify_system_app(app)

    def test_full_bundle_checks_the_transitive_graph_for_each_architecture_and_initializes_libmpv(self):
        app = self.app.parents[2]
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "SeatSix", "CFBundleIconFile": "SeatSix.icns", "LSMinimumSystemVersion": "14.0"
        }))
        self.file("app/Contents/Resources/SeatSix.icns").write_bytes(b"icns")
        self.file("app/Contents/Resources/LICENSE")
        self.file("app/Contents/Resources/ThirdPartyNotices/COPYING")
        mpv = self.file("app/Contents/Frameworks/libmpv.2.dylib")
        codec = self.file("app/Contents/Frameworks/libcodec.dylib")
        good = {
            self.app: bundle.Metadata((bundle.FRAMEWORK_PREFIX + mpv.name,), (), minimum_macos="14.0"),
            mpv: bundle.Metadata(("@rpath/" + codec.name,), ("@loader_path",), "@rpath/" + mpv.name, "11.0"),
            codec: bundle.Metadata(("/usr/lib/libSystem.B.dylib",), (), "@rpath/" + codec.name, "11.0")
        }
        with mock.patch.object(bundle, "run", return_value="arm64 x86_64"), \
                mock.patch.object(bundle, "test_bundled_mpv") as initialize, \
                mock.patch.object(bundle, "metadata", side_effect=lambda path, cpu: good[path]) as read:
            bundle.verify_full_app(app)
            initialize.assert_called_once_with(mpv)
            self.assertEqual({call.args for call in read.call_args_list},
                             {(path, cpu) for path in good for cpu in ("arm64", "x86_64")})
        for dep, rpaths, minimum in [
            ("/opt/homebrew/lib/extra.dylib", (), "11.0"),
            ("@rpath/../libmpv.2.dylib", (), "11.0"),
            ("@rpath/missing.dylib", (), "11.0"),
            ("/usr/lib/libSystem.B.dylib", ("/usr/local/lib",), "11.0"),
            ("/usr/lib/libSystem.B.dylib", (), "15.0"),
        ]:
            bad = bundle.Metadata((dep,), rpaths, "@rpath/" + codec.name, minimum)
            with self.subTest(dep=dep, rpaths=rpaths, minimum=minimum), \
                    mock.patch.object(bundle, "run", return_value="arm64 x86_64"), \
                    mock.patch.object(bundle, "metadata", side_effect=lambda path, cpu:
                                      bad if cpu == "x86_64" and path == codec else good[path]), \
                    mock.patch.object(bundle, "test_bundled_mpv") as initialize, self.assertRaises(bundle.BundleError):
                bundle.verify_full_app(app)
            initialize.assert_not_called()
        with mock.patch.object(bundle, "run", side_effect=lambda cmd, option, path:
                               "arm64" if path == codec else "arm64 x86_64"), self.assertRaisesRegex(bundle.BundleError, "universal"):
            bundle.verify_full_app(app)
        (app / "Contents/Resources/ThirdPartyNotices/unsafe").symlink_to("/example")
        with self.assertRaisesRegex(bundle.BundleError, "ThirdPartyNotices"):
            bundle.verify_full_app(app)


if __name__ == "__main__":
    unittest.main()
