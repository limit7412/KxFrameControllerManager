# 実行環境。
# ファイルの置き場所、ログ、主ループ、表示の言語を担う。
module Runtime
  # 設定、ログ、生成するマニフェストの置き場所（仕様書 6.2 節）。
  #
  # どれも利用者のホームの下に置く。SteamOS の更新はホームの外を上書きする前提であり、
  # sudo も使わないため、`~` の外には書かない（仕様書 2 章）。
  # 場所は XDG Base Directory の環境変数に従い、無ければその既定値を使う。
  module Paths
    APP_DIRECTORY_NAME = "KxFrameControllerManager"

    # 設定。既定は ~/.config/KxFrameControllerManager/。
    def self.config_directory : String
      File.join(xdg("XDG_CONFIG_HOME", ".config"), APP_DIRECTORY_NAME)
    end

    # ログと、戻し忘れを防ぐための状態ファイル。既定は ~/.local/state/KxFrameControllerManager/。
    def self.state_directory : String
      File.join(xdg("XDG_STATE_HOME", File.join(".local", "state")), APP_DIRECTORY_NAME)
    end

    # SteamVR へ渡す vrmanifest とアクションマニフェスト。既定は ~/.local/share/KxFrameControllerManager/。
    def self.data_directory : String
      File.join(xdg("XDG_DATA_HOME", File.join(".local", "share")), APP_DIRECTORY_NAME)
    end

    def self.config_path : String
      File.join(config_directory, "config.json")
    end

    def self.log_directory : String
      File.join(state_directory, "logs")
    end

    def self.manifest_path : String
      File.join(data_directory, "kx-frame-controller-manager.vrmanifest")
    end

    # SteamVR Input のアクションマニフェストと既定バインドを書き出すディレクトリ。
    def self.actions_directory : String
      File.join(data_directory, "actions")
    end

    def self.action_manifest_path : String
      File.join(actions_directory, "actions.json")
    end

    # 省電力で変える前の値（仕様書 3.8 節）。
    def self.power_save_state_path : String
      File.join(state_directory, "power_save.json")
    end

    # 自動更新の状態（最後に確かめた時刻、戻した版）。
    def self.update_state_path : String
      File.join(state_directory, "update.json")
    end

    # 常駐が起動したときに残す印。自動更新が、置き換えた版の起動を確かめるのに使う。
    def self.running_marker_path : String
      File.join(state_directory, "running.json")
    end

    # 更新を 1 つずつ走らせるための排他のファイル。
    def self.update_lock_path : String
      File.join(state_directory, "update.lock")
    end

    # systemd のユーザーユニット（仕様書 6.2 節）。
    def self.systemd_unit_path(env = ENV) : String
      File.join(xdg("XDG_CONFIG_HOME", ".config", env), "systemd", "user", "kx-frame-controller-manager.service")
    end

    # 起動した実行ファイルの絶対パス。
    # vrmanifest の binary_path_linux と、更新での置き換えに使う。
    def self.executable_path : String
      Process.executable_path || File.expand_path(PROGRAM_NAME)
    end

    # 取得しておいた新しい実行ファイル。
    #
    # 実行ファイルの隣に置くのは、置き換えが同じファイルシステム内のリネームで済むようにするためである。
    # ファイルシステムをまたぐと、リネームが中身の複写に化けて途中で失敗しうる。
    def self.staged_executable_path : String
      "#{executable_path}.new"
    end

    # XDG Base Directory の環境変数を読む。
    #
    # 仕様では、相対パスが入っていたら無効として扱い、既定値を使う。
    # 空の場合も同じである。どちらもそのまま使うと、起動した場所によって置き場所が変わる。
    def self.xdg(variable : String, fallback : String, env = ENV) : String
      value = env[variable]?
      return value if value && !value.empty? && Path.new(value).absolute?

      File.join(home(env), fallback)
    end

    private def self.home(env) : String
      env["HOME"]?.presence || Path.home.to_s
    end
  end
end
