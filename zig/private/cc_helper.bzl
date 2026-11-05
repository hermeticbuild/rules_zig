"""Utility functions for interacting with CC toolchains."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", find_rules_cc_toolchain = "find_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

def need_translate_c(cc_info):
    return cc_info.compilation_context and (cc_info.compilation_context.headers or cc_info.compilation_context.defines)

def find_cc_toolchain(ctx, *, mandatory, exec_group = None, features = [], disabled_features = []):
    """Extracts a CcToolchain from the current target's context

    Args:
        ctx (ctx): The current target's rule context object
        mandatory (bool): Whether the toolchain is mandatory
        exec_group (str|None): Execution group to read, or the default context when None
        features (list): A list of features to enable in the toolchain
        disabled_features (list): A list of features to disable in the toolchain

    Returns:
        tuple: A tuple of (CcToolchain, FeatureConfiguration)
    """
    if exec_group == None:
        cc_toolchain = find_rules_cc_toolchain(ctx, mandatory = mandatory)
    else:
        cc_toolchain = ctx.exec_groups[exec_group].toolchains[CC_TOOLCHAIN_TYPE]

        # Match rules_cc's conversion from ToolchainInfo to CcToolchainInfo.
        if hasattr(cc_toolchain, "cc_provider_in_toolchain") and hasattr(cc_toolchain, "cc"):
            cc_toolchain = cc_toolchain.cc

    if cc_toolchain == None:
        if mandatory:
            fail("Unable to find a C/C++ toolchain for {} in execution group {}.".format(ctx.label, exec_group))
        return None, None

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features + features,
        unsupported_features = ctx.disabled_features + disabled_features,
    )
    return cc_toolchain, feature_configuration
