# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Utility functions not specific to the rust toolchain."""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", find_rules_cc_toolchain = "find_cpp_toolchain")
load(":providers.bzl", "BuildInfo", "CrateInfo", "DepInfo", "DepVariantInfo")

def find_toolchain(ctx):
    """Finds the first rust toolchain that is configured.

    Args:
        ctx (ctx): The ctx object for the current target.

    Returns:
        rust_toolchain: A Rust toolchain context.
    """
    return ctx.toolchains[Label("//rust:toolchain")]

def find_cc_toolchain(ctx):
    """Extracts a CcToolchain from the current target's context

    Args:
        ctx (ctx): The current target's rule context object

    Returns:
        tuple: A tuple of (CcToolchain, FeatureConfiguration)
    """
    cc_toolchain = find_rules_cc_toolchain(ctx)

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    return cc_toolchain, feature_configuration

# TODO: Replace with bazel-skylib's `path.dirname`. This requires addressing some
# dependency issues or generating docs will break.
def relativize(path, start):
    """Returns the relative path from start to path.

    Args:
        path (str): The path to relativize.
        start (str): The ancestor path against which to relativize.

    Returns:
        str: The portion of `path` that is relative to `start`.
    """
    src_parts = _path_parts(start)
    dest_parts = _path_parts(path)
    n = 0
    done = False
    for src_part, dest_part in zip(src_parts, dest_parts):
        if src_part != dest_part:
            break
        n += 1

    relative_path = ""
    for i in range(n, len(src_parts)):
        relative_path += "../"
    relative_path += "/".join(dest_parts[n:])

    return relative_path

def _path_parts(path):
    """Takes a path and returns a list of its parts with all "." elements removed.

    The main use case of this function is if one of the inputs to relativize()
    is a relative path, such as "./foo".

    Args:
      path (str): A string representing a unix path

    Returns:
      list: A list containing the path parts with all "." elements removed.
    """
    path_parts = path.split("/")
    return [part for part in path_parts if part != "."]

def get_lib_name(lib):
    """Returns the name of a library artifact, eg. libabc.a -> abc

    Args:
        lib (File): A library file

    Returns:
        str: The name of the library
    """

    # NB: The suffix may contain a version number like 'so.1.2.3'
    libname = lib.basename.split(".", 1)[0]

    if libname.startswith("lib"):
        return libname[3:]
    else:
        return libname

def determine_output_hash(crate_root):
    """Generates a hash of the crate root file's path.

    Args:
        crate_root (File): The crate's root file (typically `lib.rs`).

    Returns:
        str: A string representation of the hash.
    """
    return repr(hash(crate_root.path))

def get_preferred_artifact(library_to_link):
    """Get the first available library to link from a LibraryToLink object.

    Args:
        library_to_link (LibraryToLink): See the followg links for additional details:
            https://docs.bazel.build/versions/master/skylark/lib/LibraryToLink.html

    Returns:
        File: Returns the first valid library type (only one is expected)
    """
    return (
        library_to_link.static_library or
        library_to_link.pic_static_library or
        library_to_link.interface_library or
        library_to_link.dynamic_library
    )

def _expand_location(ctx, env, data):
    """A trivial helper for `_expand_locations`

    Args:
        ctx (ctx): The rule's context object
        env (str): The value possibly containing location macros to expand.
        data (sequence of Targets): see `_expand_locations`

    Returns:
        string: The location-macro expanded version of the string.
    """
    for directive in ("$(execpath ", "$(location "):
        if directive in env:
            # build script runner will expand pwd to execroot for us
            env = env.replace(directive, "${pwd}/" + directive)
    return ctx.expand_location(env, data)

def expand_dict_value_locations(ctx, env, data):
    """Performs location-macro expansion on string values.

    $(execroot ...) and $(location ...) are prefixed with ${pwd},
    which process_wrapper and build_script_runner will expand at run time
    to the absolute path. This is necessary because include_str!() is relative
    to the currently compiled file, and build scripts run relative to the
    manifest dir, so we can not use execroot-relative paths.

    $(rootpath ...) is unmodified, and is useful for passing in paths via
    rustc_env that are encoded in the binary with env!(), but utilized at
    runtime, such as in tests. The absolute paths are not usable in this case,
    as compilation happens in a separate sandbox folder, so when it comes time
    to read the file at runtime, the path is no longer valid.

    See [`expand_location`](https://docs.bazel.build/versions/main/skylark/lib/ctx.html#expand_location) for detailed documentation.

    Args:
        ctx (ctx): The rule's context object
        env (dict): A dict whose values we iterate over
        data (sequence of Targets): The targets which may be referenced by
            location macros. This is expected to be the `data` attribute of
            the target, though may have other targets or attributes mixed in.

    Returns:
        dict: A dict of environment variables with expanded location macros
    """
    return dict([(k, _expand_location(ctx, v, data)) for (k, v) in env.items()])

def expand_list_element_locations(ctx, args, data):
    """Performs location-macro expansion on a list of string values.

    $(execroot ...) and $(location ...) are prefixed with ${pwd},
    which process_wrapper and build_script_runner will expand at run time
    to the absolute path.

    See [`expand_location`](https://docs.bazel.build/versions/main/skylark/lib/ctx.html#expand_location) for detailed documentation.

    Args:
        ctx (ctx): The rule's context object
        args (list): A list we iterate over
        data (sequence of Targets): The targets which may be referenced by
            location macros. This is expected to be the `data` attribute of
            the target, though may have other targets or attributes mixed in.

    Returns:
        list: A list of arguments with expanded location macros
    """
    return [_expand_location(ctx, arg, data) for arg in args]

def name_to_crate_name(name):
    """Converts a build target's name into the name of its associated crate.

    Crate names cannot contain certain characters, such as -, which are allowed
    in build target names. All illegal characters will be converted to
    underscores.

    This is a similar conversion as that which cargo does, taking a
    `Cargo.toml`'s `package.name` and canonicalizing it

    Note that targets can specify the `crate_name` attribute to customize their
    crate name; in situations where this is important, use the
    crate_name_from_attr() function instead.

    Args:
        name (str): The name of the target.

    Returns:
        str: The name of the crate for this target.
    """
    return name.replace("-", "_")

def _invalid_chars_in_crate_name(name):
    """Returns any invalid chars in the given crate name.

    Args:
        name (str): Name to test.

    Returns:
        list: List of invalid characters in the crate name.
    """

    return dict([(c, ()) for c in name.elems() if not (c.isalnum() or c == "_")]).keys()

def crate_name_from_attr(attr):
    """Returns the crate name to use for the current target.

    Args:
        attr (struct): The attributes of the current target.

    Returns:
        str: The crate name to use for this target.
    """
    if hasattr(attr, "crate_name") and attr.crate_name:
        invalid_chars = _invalid_chars_in_crate_name(attr.crate_name)
        if invalid_chars:
            fail("Crate name '{}' contains invalid character(s): {}".format(
                attr.crate_name,
                " ".join(invalid_chars),
            ))
        return attr.crate_name

    crate_name = name_to_crate_name(attr.name)
    invalid_chars = _invalid_chars_in_crate_name(crate_name)
    if invalid_chars:
        fail(
            "Crate name '{}' ".format(crate_name) +
            "derived from Bazel target name '{}' ".format(attr.name) +
            "contains invalid character(s): {}\n".format(" ".join(invalid_chars)) +
            "Consider adding a crate_name attribute to set a valid crate name",
        )
    return crate_name

def dedent(doc_string):
    """Remove any common leading whitespace from every line in text.

    This functionality is similar to python's `textwrap.dedent` functionality
    https://docs.python.org/3/library/textwrap.html#textwrap.dedent

    Args:
        doc_string (str): A docstring style string

    Returns:
        str: A string optimized for stardoc rendering
    """
    lines = doc_string.splitlines()
    if not lines:
        return doc_string

    # If the first line is empty, use the second line
    first_line = lines[0]
    if not first_line:
        first_line = lines[1]

    # Detect how much space prepends the first line and subtract that from all lines
    space_count = len(first_line) - len(first_line.lstrip())

    # If there are no leading spaces, do not alter the docstring
    if space_count == 0:
        return doc_string
    else:
        # Remove the leading block of spaces from the current line
        block = " " * space_count
        return "\n".join([line.replace(block, "", 1).rstrip() for line in lines])

def make_static_lib_symlink(actions, rlib_file):
    """Add a .a symlink to an .rlib file.

    The name of the symlink is derived from the <name> of the <name>.rlib file as follows:
    * `<name>.a`, if <name> starts with `lib`
    * `lib<name>.a`, otherwise.

    For example, the name of the symlink for
    * `libcratea.rlib` is `libcratea.a`
    * `crateb.rlib` is `libcrateb.a`.

    Args:
        actions (actions): The rule's context actions object.
        rlib_file (File): The file to symlink, which must end in .rlib.

    Returns:
        The symlink's File.
    """
    if not rlib_file.basename.endswith(".rlib"):
        fail("file is not an .rlib: ", rlib_file.basename)
    basename = rlib_file.basename[:-5]
    if not basename.startswith("lib"):
        basename = "lib" + basename
    dot_a = actions.declare_file(basename + ".a", sibling = rlib_file)
    actions.symlink(output = dot_a, target_file = rlib_file)
    return dot_a

def is_exec_configuration(ctx):
    """Determine if a context is building for the exec configuration.

    This is helpful when processing command line flags that should apply
    to the target configuration but not the exec configuration.

    Args:
        ctx (ctx): The ctx object for the current target.

    Returns:
        True if the exec configuration is detected, False otherwise.
    """

    # TODO(djmarcin): Is there any better way to determine cfg=exec?
    return ctx.genfiles_dir.path.find("-exec-") == -1

def transform_deps(deps, make_rust_providers_target_independent):
    """Conditionally transform a [Target] into [DepVariantInfo].

    This helper function is used to transform ctx.attr.deps and ctx.attr.proc_macro_deps into
    [DepVariantInfo] when --//rust/settings:incompatible_make_rust_providers_target_independent
    is set to true (https://github.com/bazelbuild/rules_rust/issues/966).
    Do not rely on this function - it will be removed after the flag is flipped.

    Args:
        deps (list of Targets): Dependencies comming from ctx.attr.deps or ctx.attr.proc_macro_deps
        make_rust_providers_target_independent (bool): The value of
            --//rust/settings:incompatible_make_rust_providers_target_independent.

    Returns:
        list of DepVariantInfos if --//rust/settings:incompatible_make_rust_providers_target has
        been flipped, list of Targets otherwise.
    """
    return [DepVariantInfo(
        crate_info = dep[CrateInfo] if CrateInfo in dep else None,
        dep_info = dep[DepInfo] if DepInfo in dep else None,
        build_info = dep[BuildInfo] if BuildInfo in dep else None,
        cc_info = dep[CcInfo] if CcInfo in dep else None,
    ) for dep in deps] if make_rust_providers_target_independent else deps
