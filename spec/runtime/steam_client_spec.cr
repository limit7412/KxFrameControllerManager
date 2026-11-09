require "../spec_helper"
require "../../src/runtime/steam_client"

# Steam が Linux で書く registry.vdf の形を、要る部分だけ写したもの。
private REGISTRY = <<-VDF
  "Registry"
  {
  	"HKCU"
  	{
  		"Software"
  		{
  			"Valve"
  			{
  				"Steam"
  				{
  					"AutoLoginUser"		"someone"
  					"apps"
  					{
  						"250820"
  						{
  							"language"		"german"
  						}
  					}
  					"language"		"japanese"
  					"SourceModInstallPath"		"C:\\\\Program Files\\\\Steam"
  				}
  			}
  		}
  	}
  }
  VDF

describe Runtime::SteamClient do
  # アプリごとの設定にも language がある。Steam そのものの表示言語だけを拾う。
  it "Steam の表示言語を取り出し、アプリごとの language は見ない" do
    Runtime::SteamClient.language_in(REGISTRY).should eq "japanese"
  end

  it "キーの大文字と小文字を区別しない" do
    text = %("registry" { "hkcu" { "SOFTWARE" { "valve" { "steam" { "Language" "schinese" } } } } })
    Runtime::SteamClient.language_in(text).should eq "schinese"
  end

  it "表示言語が無ければ nil を返す" do
    Runtime::SteamClient.language_in(%("Registry" { "HKCU" { } })).should be_nil
    Runtime::SteamClient.language_in("").should be_nil
  end

  it "ファイルが無ければ nil を返す" do
    Runtime::SteamClient.language({"HOME" => "/nonexistent-kxfcm"}).should be_nil
  end

  it "HOME の下の .steam/registry.vdf を読む" do
    dir = File.tempname("kxfcm-steam")
    Dir.mkdir_p(File.join(dir, ".steam"))
    File.write(File.join(dir, ".steam", "registry.vdf"), REGISTRY)
    Runtime::SteamClient.language({"HOME" => dir}).should eq "japanese"
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
