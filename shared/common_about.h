#pragma once

//
// Common branding and about page macros for all foobar2000 macOS components
//

#define JL_AUTHOR "Jenda Legenda"
#define JL_GITHUB_URL "https://github.com/JendaT/fb2k-components-mac-suite"
#define JL_KOFI_URL "https://ko-fi.com/jendalegenda"

//
// Macro for DECLARE_COMPONENT_VERSION with unified branding
//
// The description is a one-line summary, then the layout element name (what
// the user types in the layout editor), then the feature list:
//
//   JL_COMPONENT_ABOUT(
//       "My Extension",
//       "1.0.0",
//       "Description of the extension.\n\n"
//       "Layout element: my_extension\n\n"
//       "Features:\n"
//       "- Feature 1\n"
//       "- Feature 2"
//   );
//
// JL_COMPONENT_ABOUT_BY takes the author for components written by a contributor.
//
#define JL_COMPONENT_ABOUT_BY(name, version, author, description) \
    DECLARE_COMPONENT_VERSION(name, version, \
        description "\n\n" \
        "Author: " author "\n" \
        "Source: " JL_GITHUB_URL "\n" \
        "Support: " JL_KOFI_URL "\n" \
        "License: MIT (free and open source)")

#define JL_COMPONENT_ABOUT(name, version, description) \
    JL_COMPONENT_ABOUT_BY(name, version, JL_AUTHOR, description)
