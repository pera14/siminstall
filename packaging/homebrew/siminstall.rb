cask "siminstall" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE"

  url "https://github.com/pera14/siminstall/releases/download/v#{version}/SimInstall-#{version}.dmg"
  name "SimInstall"
  desc "Install iOS Simulator builds (.app or EAS .tar.gz) with one click"
  homepage "https://github.com/pera14/siminstall"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "SimInstall.app"

  zap trash: [
    "~/Library/Preferences/io.github.siminstall.plist",
    "~/Library/Saved Application State/io.github.siminstall.savedState",
  ]
end
