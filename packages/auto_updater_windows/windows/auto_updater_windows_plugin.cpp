#include "auto_updater_windows_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

// #include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>

namespace auto_updater_windows {

// static
void AutoUpdaterWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "dev.leanflutter.plugins/auto_updater",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<AutoUpdaterWindowsPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "dev.leanflutter.plugins/auto_updater_event",
          &flutter::StandardMethodCodec::GetInstance());
  auto streamHandler = std::make_unique<flutter::StreamHandlerFunctions<>>(
      [plugin_pointer = plugin.get()](
          const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        return plugin_pointer->OnListen(arguments, std::move(events));
      },
      [plugin_pointer = plugin.get()](const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<>> {
        return plugin_pointer->OnCancel(arguments);
      });
  event_channel->SetStreamHandler(std::move(streamHandler));
  registrar->AddPlugin(std::move(plugin));
}

AutoUpdaterWindowsPlugin::AutoUpdaterWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar) {
  registrar_ = registrar;
}

AutoUpdaterWindowsPlugin::~AutoUpdaterWindowsPlugin() {}

void AutoUpdaterWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string method_name = method_call.method_name();

  if (method_name.compare("setFeedURL") == 0) {
    const flutter::EncodableMap& args =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    std::string feedURL =
        std::get<std::string>(args.at(flutter::EncodableValue("feedURL")));
    auto_updater.SetFeedURL(feedURL);
    result->Success(flutter::EncodableValue(true));

  } else if (method_name.compare("checkForUpdates") == 0) {
    const flutter::EncodableMap& args =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    bool inBackground =
        std::get<bool>(args.at(flutter::EncodableValue("inBackground")));
    if (inBackground) {
      auto_updater.CheckForUpdatesWithoutUI();
    } else {
      auto_updater.CheckForUpdates();
    }
    result->Success(flutter::EncodableValue(true));

  } else if (method_name.compare("setScheduledCheckInterval") == 0) {
    const flutter::EncodableMap& args =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    int interval = std::get<int>(args.at(flutter::EncodableValue("interval")));
    auto_updater.SetScheduledCheckInterval(interval);
    result->Success(flutter::EncodableValue(true));

  } else if (method_name.compare("setHttpHeaders") == 0) {
    const flutter::EncodableMap& args =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    const flutter::EncodableMap& headers =
        std::get<flutter::EncodableMap>(args.at(flutter::EncodableValue("headers")));
    win_sparkle_clear_http_headers();
    for (auto it = headers.begin(); it != headers.end(); ++it) {
      if (std::holds_alternative<std::string>(it->first) &&
          std::holds_alternative<std::string>(it->second)) {
        std::string name = std::get<std::string>(it->first);
        std::string value = std::get<std::string>(it->second);
        win_sparkle_set_http_header(name.c_str(), value.c_str());
      }
    }
    result->Success(flutter::EncodableValue(true));

  } else {
    result->NotImplemented();
  }
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
AutoUpdaterWindowsPlugin::OnListenInternal(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  auto_updater.RegisterEventSink(std::move(events));
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
AutoUpdaterWindowsPlugin::OnCancelInternal(
    const flutter::EncodableValue* arguments) {
  auto_updater.RegisterEventSink(nullptr);
  return nullptr;
}
}  // namespace auto_updater_windows
