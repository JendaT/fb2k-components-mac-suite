//
//  TitleFormatHelper.cpp
//  foo_simplaylist_mac
//

#include "TitleFormatHelper.h"

namespace simplaylist {

std::unordered_map<std::string, titleformat_object::ptr> TitleFormatHelper::s_cache;
std::mutex TitleFormatHelper::s_cacheMutex;

} // namespace simplaylist
