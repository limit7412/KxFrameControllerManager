require "json"
require "../config/usecase"
require "../power_off/models"

module SteamVR
  # 既定バインド（bindings_frame_controller.json）の組み立て（仕様書 3.1 節）。
  #
  # 長押しに使うボタンを設定 input.left_button と input.right_button から差し込む。
  # SteamVR のバインド画面で利用者が別のバインドを選んでいれば、SteamVR はそちらを使う。
  # ここで変えられるのは、利用者が何も選んでいないときに使われる既定だけである。
  module Bindings
    # 長押しに割り当てられるボタン。frame_controller の入力プロファイル
    # （SteamVR の drivers/frame_controller/resources/input/frame_controller_profile.json）のうち、
    # その手にあり、click を持つものに限る。
    #
    # system（Steam ボタン）はアプリから読めない見込みのため外す（仕様書 2 章）。
    # trigger と grip はゲームで常に使うため外す。長押しで切断する操作と衝突しやすい。
    LEFT_BUTTONS  = %w[view dpad_up dpad_down dpad_left dpad_right bumper thumbstick]
    RIGHT_BUTTONS = %w[menu a b x y bumper thumbstick]

    def self.buttons(hand : PowerOff::Hand) : Array(String)
      hand.left? ? LEFT_BUTTONS : RIGHT_BUTTONS
    end

    def self.button(section : Config::InputSection, hand : PowerOff::Hand) : String
      hand.left? ? section.left_button : section.right_button
    end

    # input セクションのボタンの名前を確かめる。config の usecase へ登録して使う。
    def self.validate(section : Config::InputSection) : Array(Config::Problem)
      errors = [] of Config::Problem
      PowerOff::Hand.each do |hand|
        name = button(section, hand)
        next if buttons(hand).includes?(name)
        errors << Config::Usecase.choice_problem("#{hand.label}_button", buttons(hand))
      end
      errors
    end

    # アクションマニフェストの雛形の localization を、渡した表で置き換える。
    #
    # 表の 1 行は SteamVR の言語の札（language_tag）と、アクションのパスごとの名前である。
    # SteamVR のバインド画面は、Steam の表示言語に合う行の名前を出す。
    def self.localize(template : String, entries : Array(Hash(String, String))) : String
      root = JSON.parse(template).as_h
      root["localization"] = JSON::Any.new(entries.map do |entry|
        JSON::Any.new(entry.transform_values { |value| JSON::Any.new(value) })
      end)
      root.to_pretty_json
    end

    # 既定バインドの雛形の、長押しのアクションへつながる入力の場所を差し替える。
    #
    # 雛形の左手の入力は left_button へ、右手の入力は right_button へ置き換える。
    # 知らない名前は雛形のまま残す。検証を通らない経路でも、壊れたバインドを書き出さないためである。
    def self.render(template : String, section : Config::InputSection) : String
      root = JSON.parse(template)
      sources = root.dig?("bindings", "/actions/kxfcm", "sources").try(&.as_a?)
      return template unless sources

      sources.each do |source|
        object = source.as_h?
        next unless object
        path = object["path"]?.try(&.as_s?)
        next unless path
        PowerOff::Hand.each do |hand|
          prefix = "/user/hand/#{hand.label}/input/"
          next unless path.starts_with?(prefix)
          name = button(section, hand)
          object["path"] = JSON::Any.new(prefix + name) if buttons(hand).includes?(name)
        end
      end
      root.to_pretty_json
    end
  end
end
