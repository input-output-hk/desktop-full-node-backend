package ourpaths

import (
	"os"
	"os/user"
	"path/filepath"
	"runtime"
)

const (
	OurLogPrefix = "blockfrost-platform-desktop"
)

var (
	ExecutablePath string
	Username string
	WorkDir string
	LibexecDir string
	ResourcesDir string
	NetworkConfigDir string
	CardanoServicesDir string
	ExeSuffix string
)

func init() {
	var err error

	ExecutablePath, err = os.Executable()
	if err != nil {
		panic(err)
	}

	ExecutablePath, err = filepath.EvalSymlinks(ExecutablePath)
	if err != nil {
		panic(err)
	}

	currentUser, err := user.Current()
	if err != nil {
		panic(err)
	}
	Username = currentUser.Username

	binDir := filepath.Dir(ExecutablePath)

	switch runtime.GOOS {
	case "darwin":
		WorkDir = currentUser.HomeDir + "/Library/Application Support/blockfrost-platform-desktop"
		LibexecDir = binDir
		ResourcesDir = filepath.Clean(binDir + "/../Resources")
	case "linux":
		WorkDir = currentUser.HomeDir + "/.local/share/blockfrost-platform-desktop"
		LibexecDir = filepath.Clean(binDir + "/../../libexec")
		ResourcesDir = filepath.Clean(binDir + "/../../share")
	case "windows":
		WorkDir = os.Getenv("AppData") + "\\blockfrost-platform-desktop"
		LibexecDir = filepath.Clean(binDir + "\\libexec")
		ResourcesDir = binDir
	default:
		panic("cannot happen, unknown OS: " + runtime.GOOS)
	}

	sep := string(filepath.Separator)

	NetworkConfigDir = ResourcesDir + sep + "cardano-node-config"

	CardanoServicesDir = ResourcesDir + sep + "cardano-js-sdk" + sep + "packages" + sep + "cardano-services"

	ExeSuffix = ""
	if runtime.GOOS == "windows" {
		ExeSuffix = ".exe"
	}
}
