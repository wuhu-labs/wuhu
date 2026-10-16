"""The host a lane's tests run on, as a toolchain for a test exec group."""

def _test_host_impl(_ctx):
    return [platform_common.ToolchainInfo()]

test_host = rule(implementation = _test_host_impl)
