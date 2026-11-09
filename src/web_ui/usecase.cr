require "json"
require "log"
require "../config/usecase"
require "../power_off/models"
require "./models"

module WebUI
  # 画面へ返す応答。status は HTTP の状態コード、body は JSON である。
  record Response, status : Int32, body : String

  # 画面が呼ぶ操作（状態の取得、設定の取得と保存、手動の切断、27062 の一覧）。
  #
  # HTTP を知らず、JSON の文字列を受けて Response を返す。
  # 常駐の部品には composition root が渡す Proc を通して触れ、他のコンテキストの具象型を知らない。
  class Usecase
    Log = ::Log.for("web_ui")

    # 常駐の状態を組み立てる。
    property status : Proc(Snapshot) = -> { raise "status が渡されていない" }
    # 手を指定して切る。処理中で受け付けられなければ nil を返す。
    property disconnect : Proc(Array(PowerOff::Hand), Array(PowerOff::Result)?) = ->(_hands : Array(PowerOff::Hand)) { nil.as(Array(PowerOff::Result)?) }
    # 27062 から一覧を取る。取れなければ nil を返す。
    property controllers : Proc(PowerOff::ControllerList?) = -> { nil.as(PowerOff::ControllerList?) }
    # 長押しに割り当てられるボタン。
    property buttons : Hash(String, Array(String)) = {} of String => Array(String)

    def initialize(@config : Config::Usecase)
    end

    def state : Response
      Response.new(200, @status.call.to_json)
    end

    # 画面が扱う項目の現在値と、選べるボタンを返す。
    def config : Response
      body = JSON.build do |json|
        json.object do
          json.field "config", WebUI.editable(@config.current)
          json.field "buttons", @buttons
        end
      end
      Response.new(200, body)
    end

    # 変更を重ねた設定を検証し、通れば保存して反映する。
    # 通らなければ何も変えず、誤りの一覧を返す。
    def save(body : String) : Response
      root = WebUI.merge(@config.current, JSON.parse(body))
      errors = @config.save(root)
      unless errors.empty?
        return error(422, errors.map(&.to_s))
      end
      config
    rescue exception : PatchError
      error(400, [exception.message || "変更を読めなかった"])
    rescue exception : JSON::ParseException
      error(400, ["JSON として読めなかった: #{exception.message}"])
    rescue exception : File::Error
      Log.error(exception: exception) { "設定画面からの保存に失敗した" }
      error(500, ["設定ファイルへ書けなかった: #{exception.message}"])
    end

    # 手動の切断。body は {"target": "left" | "right" | "both"} である。
    def disconnect(body : String) : Response
      target = JSON.parse(body)["target"]?.try(&.as_s?)
      hands = case target
              when "left"  then [PowerOff::Hand::Left]
              when "right" then [PowerOff::Hand::Right]
              when "both"  then [PowerOff::Hand::Left, PowerOff::Hand::Right]
              else              return error(400, ["target は left / right / both のいずれかで指定する"])
              end

      results = @disconnect.call(hands)
      return error(409, ["前の切断を処理中"]) unless results

      body = JSON.build do |json|
        json.object do
          json.field "results" do
            json.array do
              results.each do |result|
                json.object do
                  json.field "target", result.target.label
                  json.field "serial", result.target.serial
                  json.field "outcome", result.outcome.to_s.underscore
                end
              end
            end
          end
        end
      end
      Response.new(200, body)
    rescue exception : JSON::ParseException
      error(400, ["JSON として読めなかった: #{exception.message}"])
    end

    # 27062 の一覧。要求のたびに 27062 へ接続するため、画面は利用者が求めたときだけ呼ぶ。
    def controllers : Response
      list = @controllers.call
      return error(502, ["27062 に届かなかった"]) unless list

      body = JSON.build do |json|
        json.object do
          json.field "connected" do
            json.array do
              list.connected.each do |controller|
                json.object do
                  json.field "serial", controller.serial
                  json.field "hand", controller.hand.try(&.label)
                end
              end
            end
          end
          json.field "paired", list.paired.reject { |serial| list.connected?(serial) }
        end
      end
      Response.new(200, body)
    end

    private def error(status : Int32, messages : Array(String)) : Response
      Response.new(status, {errors: messages}.to_json)
    end
  end
end
