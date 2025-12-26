#pragma once

//
// Common branding and about page macros for all foobar2000 macOS components
//

#define JL_AUTHOR "Jenda Legenda"
#define JL_GITHUB_URL "https://github.com/JendaT/fb2k-components-mac-suite"
#define JL_KOFI_URL "https://ko-fi.com/jendalegenda"
#define JL_COPYRIGHT_YEAR "2025"

//
// Macro for DECLARE_COMPONENT_VERSION with unified branding
//
// Usage:
//   JL_COMPONENT_ABOUT(
//       "My Extension",
//       "1.0.0",
//       "Description of the extension.\n\n"
//       "Features:\n"
//       "- Feature 1\n"
//       "- Feature 2"
//   );
//
#define JL_COMPONENT_ABOUT(name, version, description) \
    DECLARE_COMPONENT_VERSION(name, version, \
        description "\n\n" \
        "Author: " JL_AUTHOR "\n" \
        "Source: " JL_GITHUB_URL "\n" \
        "Support: " JL_KOFI_URL "\n" \
        "Copyright (c) " JL_COPYRIGHT_YEAR " " JL_AUTHOR)
