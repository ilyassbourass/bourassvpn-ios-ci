#!/usr/bin/env python3
"""Patch ios/Runner.xcodeproj/project.pbxproj to add the TunnelExtension
appex target (PacketTunnelProvider), the BourassEngine local SwiftPM
dependency, the embed phase, NetworkExtension framework links, bundle IDs,
and entitlements. Idempotent: re-running detects the marker and skips.
"""
import re
import sys

PBX = "ios/Runner.xcodeproj/project.pbxproj"

# Deterministic 24-hex-char IDs (namespace AAAAAA... — no collision risk
# with the template's 97C1.../331C.../78A3... IDs).
F_APPX = "AAAAAA0000000000000000A1"
F_SRC = "AAAAAA0000000000000000A2"
B_SRC = "AAAAAA0000000000000000A3"
F_NE = "AAAAAA0000000000000000A4"
T_APPX = "AAAAAA0000000000000000B1"
PH_SRC = "AAAAAA0000000000000000B2"
PH_FRW = "AAAAAA0000000000000000B3"
L_CFG = "AAAAAA0000000000000000B4"
C_DBG = "AAAAAA0000000000000000B5"
C_REL = "AAAAAA0000000000000000B6"
C_PRO = "AAAAAA0000000000000000B7"
PH_EMB = "AAAAAA0000000000000000C1"
B_EMB = "AAAAAA0000000000000000C2"
P_PRX = "AAAAAA0000000000000000C3"
D_TGT = "AAAAAA0000000000000000C4"
B_NE_R = "AAAAAA0000000000000000C5"
B_NE_A = "AAAAAA0000000000000000C6"
G_EXT = "AAAAAA0000000000000000E1"
P_PKG = "AAAAAA0000000000000000D1"
D_PKG = "AAAAAA0000000000000000D2"

PROJECT_OBJECT = "97C146E61CF9000F007C117D"
RUNNER_TARGET = "97C146ED1CF9000F007C117D"
RUNNER_FRW = "97C146EB1CF9000F007C117D"
PRODUCTS_GROUP = "97C146EF1CF9000F007C117D"
MAIN_GROUP = "97C146E51CF9000F007C117D"


def appex_settings(cfg_name):
    debug = cfg_name == "Debug"
    cid = C_DBG if debug else (C_REL if cfg_name == "Release" else C_PRO)
    cond = "\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;\n" if debug else ""
    return f"""\t\t{cid} /* {cfg_name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = TunnelExtension/TunnelExtension.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = TunnelExtension/Info.plist;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.fastvpn.inwi.tunnel;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";{cond}\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = {"-Onone" if debug else "-O"};
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = {cfg_name};
\t\t}};
"""


def main():
    with open(PBX, encoding="utf-8") as f:
        text = f.read()

    if T_APPX in text:
        print("already patched — nothing to do")
        return

    # --- PBXBuildFile
    text = text.replace("/* End PBXBuildFile section */", f"""\t\t{B_SRC} /* PacketTunnelProvider.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {F_SRC} /* PacketTunnelProvider.swift */; }};
\t\t{B_EMB} /* TunnelExtension.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {F_APPX} /* TunnelExtension.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};
\t\t{B_NE_R} /* NetworkExtension.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {F_NE} /* NetworkExtension.framework */; }};
\t\t{B_NE_A} /* NetworkExtension.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {F_NE} /* NetworkExtension.framework */; }};
/* End PBXBuildFile section */""")

    # --- PBXContainerItemProxy
    text = text.replace("/* End PBXContainerItemProxy section */", f"""\t\t{P_PRX} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {PROJECT_OBJECT} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {T_APPX};
\t\t\tremoteInfo = TunnelExtension;
\t\t}};
/* End PBXContainerItemProxy section */""")

    # --- PBXCopyFilesBuildPhase
    text = text.replace("/* End PBXCopyFilesBuildPhase section */", f"""\t\t{PH_EMB} /* Embed Foundation Extensions */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\t{B_EMB} /* TunnelExtension.appex in Embed Foundation Extensions */,
\t\t\t);
\t\t\tname = "Embed Foundation Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXCopyFilesBuildPhase section */""")

    # --- PBXFileReference
    text = text.replace("/* End PBXFileReference section */", f"""\t\t{F_APPX} /* TunnelExtension.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = TunnelExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{F_SRC} /* PacketTunnelProvider.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PacketTunnelProvider.swift; sourceTree = "<group>"; }};
\t\t{F_NE} /* NetworkExtension.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = NetworkExtension.framework; path = System/Library/Frameworks/NetworkExtension.framework; sourceTree = SDKROOT; }};
/* End PBXFileReference section */""")

    # --- PBXFrameworksBuildPhase: new appex phase + NE in Runner phase
    text = text.replace("/* End PBXFrameworksBuildPhase section */", f"""\t\t{PH_FRW} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{B_NE_A} /* NetworkExtension.framework in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */""")
    text = re.sub(
        r"(97C146EB1CF9000F007C117D /\* Frameworks \*/ = \{[^}]*?files = \()",
        rf"\1\n\t\t\t\t{B_NE_R} /* NetworkExtension.framework in Frameworks */,",
        text)

    # --- PBXGroup: TunnelExtension group + products entry
    text = text.replace("/* End PBXGroup section */", f"""\t\t{G_EXT} /* TunnelExtension */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{F_SRC} /* PacketTunnelProvider.swift */,
\t\t\t);
\t\t\tpath = TunnelExtension;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */""")
    text = re.sub(
        rf"({PRODUCTS_GROUP} /\* Products \*/ = \{{[^}}]*?children = \()",
        rf"\1\n\t\t\t\t{F_APPX} /* TunnelExtension.appex */,",
        text)
    text = re.sub(
        rf"({MAIN_GROUP} = \{{[^}}]*?children = \()",
        rf"\1\n\t\t\t\t{G_EXT} /* TunnelExtension */,",
        text)

    # --- PBXNativeTarget: appex target + Runner buildPhases/dependencies
    text = text.replace("/* End PBXNativeTarget section */", f"""\t\t{T_APPX} /* TunnelExtension */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {L_CFG} /* Build configuration list for PBXNativeTarget "TunnelExtension" */;
\t\t\tbuildPhases = (
\t\t\t\t{PH_SRC} /* Sources */,
\t\t\t\t{PH_FRW} /* Frameworks */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = TunnelExtension;
\t\t\tpackageProductDependencies = (
\t\t\t\t{D_PKG} /* BourassEngine */,
\t\t\t);
\t\t\tproductName = TunnelExtension;
\t\t\tproductReference = {F_APPX} /* TunnelExtension.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};
/* End PBXNativeTarget section */""")
    text = text.replace(
        f"\t\t\t\t9705A1C41CF9048500538489 /* Embed Frameworks */,\n",
        f"\t\t\t\t9705A1C41CF9048500538489 /* Embed Frameworks */,\n\t\t\t\t{PH_EMB} /* Embed Foundation Extensions */,\n")
    text = text.replace(
        f"\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = Runner;",
        f"\t\t\tdependencies = (\n\t\t\t\t{D_TGT} /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = Runner;")

    # --- PBXProject: targets, packageReferences, TargetAttributes
    text = text.replace(
        f"\t\t\ttargets = (\n\t\t\t\t{RUNNER_TARGET} /* Runner */,\n\t\t\t\t331C8080294A63A400263BE5 /* RunnerTests */,\n\t\t\t);",
        f"\t\t\ttargets = (\n\t\t\t\t{RUNNER_TARGET} /* Runner */,\n\t\t\t\t{T_APPX} /* TunnelExtension */,\n\t\t\t\t331C8080294A63A400263BE5 /* RunnerTests */,\n\t\t\t);")
    text = text.replace(
        '\t\t\tpackageReferences = (\n\t\t\t\t781AD8BC2B33823900A9FFBB /* XCLocalSwiftPackageReference "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage" */,\n\t\t\t);',
        f'\t\t\tpackageReferences = (\n\t\t\t\t781AD8BC2B33823900A9FFBB /* XCLocalSwiftPackageReference "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage" */,\n\t\t\t\t{P_PKG} /* XCLocalSwiftPackageReference "../" */,\n\t\t\t);')
    text = text.replace(
                '\t\t\t\t\t97C146ED1CF9000F007C117D = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 7.3.1;',
                f'\t\t\t\t\t{T_APPX} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n\t\t\t\t\t}};\n\t\t\t\t\t97C146ED1CF9000F007C117D = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 7.3.1;')

    # --- PBXSourcesBuildPhase
    text = text.replace("/* End PBXSourcesBuildPhase section */", f"""\t\t{PH_SRC} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{B_SRC} /* PacketTunnelProvider.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */""")

    # --- PBXTargetDependency
    text = text.replace("/* End PBXTargetDependency section */", f"""\t\t{D_TGT} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {T_APPX} /* TunnelExtension */;
\t\t\ttargetProxy = {P_PRX} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */""")

    # --- XCBuildConfiguration (appex Debug/Release/Profile)
    marker = "/* End XCBuildConfiguration section */"
    add = (appex_settings("Debug") + appex_settings("Release") + appex_settings("Profile"))
    text = text.replace(marker, add + marker)

    # --- XCConfigurationList
    text = text.replace("/* End XCConfigurationList section */", f"""\t\t{L_CFG} /* Build configuration list for PBXNativeTarget "TunnelExtension" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{C_DBG} /* Debug */,
\t\t\t\t{C_REL} /* Release */,
\t\t\t\t{C_PRO} /* Profile */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */""")

    # --- XCLocalSwiftPackageReference + product dependency
    text = text.replace("/* End XCLocalSwiftPackageReference section */", f"""\t\t{P_PKG} /* XCLocalSwiftPackageReference "../" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = "..";
\t\t}};
/* End XCLocalSwiftPackageReference section */""")
    text = text.replace("/* End XCSwiftPackageProductDependency section */", f"""\t\t{D_PKG} /* BourassEngine */ = {{
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tproductName = BourassEngine;
\t\t}};
/* End XCSwiftPackageProductDependency section */""")

    # --- bundle IDs + Runner entitlements
    text = text.replace("PRODUCT_BUNDLE_IDENTIFIER = com.fastvpn.fastvpn;",
                        "PRODUCT_BUNDLE_IDENTIFIER = com.fastvpn.inwi;")
    text = text.replace("PRODUCT_BUNDLE_IDENTIFIER = com.fastvpn.fastvpn.RunnerTests;",
                        "PRODUCT_BUNDLE_IDENTIFIER = com.fastvpn.inwi.RunnerTests;")
    # Runner target configs: add entitlements right after the bundle ID line
    text = text.replace(
        "PRODUCT_BUNDLE_IDENTIFIER = com.fastvpn.inwi;",
        "PRODUCT_BUNDLE_IDENTIFIER = com.fastvpn.inwi;\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;")

    with open(PBX, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("patched:", PBX)


if __name__ == "__main__":
    main()
