package main

import (
	"embed"
	_ "embed"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"io/ioutil"
	"path/filepath"
	"runtime"
	"time"
	"encoding/json"
	"net/http"

	t "blockfrost.io/blockfrost-platform-desktop/types"
	"blockfrost.io/blockfrost-platform-desktop/constants"
	"blockfrost.io/blockfrost-platform-desktop/ourpaths"
	"blockfrost.io/blockfrost-platform-desktop/appconfig"
	"blockfrost.io/blockfrost-platform-desktop/httpapi"
	"blockfrost.io/blockfrost-platform-desktop/ui"
	"blockfrost.io/blockfrost-platform-desktop/mithrilcache"
	"blockfrost.io/blockfrost-platform-desktop/mainthread"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/mem"
	"github.com/shirou/gopsutil/v3/host"
	"github.com/shirou/gopsutil/v3/load"
	"github.com/getlantern/systray"
	"github.com/allan-simon/go-singleinstance"

	wails3_application "github.com/wailsapp/wails/v3/pkg/application"
	wails3_events "github.com/wailsapp/wails/v3/pkg/events"
)

//go:embed web-ui
var webUIAssets embed.FS

const (
	OurLogPrefix = ourpaths.OurLogPrefix
)

func main() {
	hostInfo, err := host.Info()
	if err != nil {
		panic(err)
	}

	cpuInfo, err := cpu.Info()
	if err != nil {
		panic(err)
	}

	sep := string(filepath.Separator)

	fmt.Printf("%s[%d]: work directory: %s\n", OurLogPrefix, os.Getpid(), ourpaths.WorkDir)
	os.MkdirAll(ourpaths.WorkDir, 0755)
	os.Chdir(ourpaths.WorkDir)

	lockFile := ourpaths.WorkDir + sep + "instance.lock"
	lockFileFile, err := singleinstance.CreateLockFile(lockFile)
	if err != nil {
		ui.HandleAppReopened()
		os.Exit(1)
	}
	defer lockFileFile.Close() // or else, it will be GC’d (and unlocked!)

	logFile := ourpaths.WorkDir + sep + "logs" + sep + time.Now().UTC().Format("2006-01-02--15-04-05Z") + ".log"
	fmt.Printf("%s[%d]: logging to file: %s\n", OurLogPrefix, os.Getpid(), logFile)
	os.MkdirAll(filepath.Dir(logFile), 0755)
	closeOutputs := duplicateOutputToFile(logFile)
	defer closeOutputs()

	var stdArch string
	switch runtime.GOARCH {
	case "amd64": stdArch = "x86_64"
	case "arm64": stdArch = "aarch64"
	default: stdArch = runtime.GOARCH
	}

	fmt.Printf("%s[%d]: running as %s@%s\n", OurLogPrefix, os.Getpid(),
		ourpaths.Username, hostInfo.Hostname)
	fmt.Printf("%s[%d]: logging to file: %s\n", OurLogPrefix, os.Getpid(), logFile)
	fmt.Printf("%s[%d]: executable: %s\n", OurLogPrefix, os.Getpid(), ourpaths.ExecutablePath)
	fmt.Printf("%s[%d]: work directory: %s\n", OurLogPrefix, os.Getpid(), ourpaths.WorkDir)
	fmt.Printf("%s[%d]: timezone: %s\n", OurLogPrefix, os.Getpid(), time.Now().Format("UTC-07:00 (MST)"))
	fmt.Printf("%s[%d]: HostID: %s\n", OurLogPrefix, os.Getpid(), hostInfo.HostID)
	fmt.Printf("%s[%d]: OS: (%s-%s) %s %s %s (family: %s)\n", OurLogPrefix, os.Getpid(),
		stdArch, runtime.GOOS,
		hostInfo.OS, hostInfo.Platform, hostInfo.PlatformVersion, hostInfo.PlatformFamily)
	fmt.Printf("%s[%d]: CPU: %s (%d physical thread(s), %d core(s) each, at %.2f GHz)\n",
		OurLogPrefix, os.Getpid(),
		cpuInfo[0].ModelName, len(cpuInfo), cpuInfo[0].Cores, float64(cpuInfo[0].Mhz) / 1000.0)

	logSystemHealth()
	go func() {
		for {
			time.Sleep(60 * time.Second)
			logSystemHealth()
		}
	}()

	networks, err := readAvailableNetworks()
	if err != nil { panic(err) }

	appConfig := appconfig.Load()

	commUI, commManager, commHttp := func() (ui.CommChannels, CommChannels_Manager, httpapi.CommChannels) {
		blockRestartUI := make(chan bool)

		serviceUpdateFromManager := make(chan t.ServiceStatus)
		serviceUpdateToUI := make(chan t.ServiceStatus)
		serviceUpdateToHttp := make(chan t.ServiceStatus)

		networkFromUI := make(chan string)
		networkFromHttp := make(chan t.NetworkMagic)
		networkToHttp := make(chan t.NetworkMagic)
		networkToManager := make(chan string)

		triggerMithril := make(chan struct{})

		go func(){
			reverseNetworks := map[string]t.NetworkMagic{}
			for a, b := range networks { reverseNetworks[b] = a }
			for name := range networkFromUI {
				networkToManager <- name
				networkToHttp <- reverseNetworks[name]
			}
		}()

		go func(){
			for ss := range serviceUpdateFromManager {
				serviceUpdateToUI <- ss
				serviceUpdateToHttp <- ss
			}
		}()

		serviceUpdateFromManager <- t.ServiceStatus {
			ServiceName: "blockfrost-platform-desktop",
			Status: "listening",
			Progress: -1,
			TaskSize: -1,
			SecondsLeft: -1,
			Url: fmt.Sprintf("http://127.0.0.1:%d", appConfig.ApiPort),
			Version: constants.BlockfrostPlatformDesktopVersion,
			Revision: constants.BlockfrostPlatformDesktopRevision,
		}

		initiateShutdownCh := make(chan struct{}, 16)

		return ui.CommChannels {
			ServiceUpdate: serviceUpdateToUI,
			BlockRestartUI: blockRestartUI,
			HttpSwitchesNetwork: networkFromHttp,
			NetworkSwitch: networkFromUI,
			InitiateShutdownCh: initiateShutdownCh,
			TriggerMithril: triggerMithril,
		}, CommChannels_Manager {
			ServiceUpdate: serviceUpdateFromManager,
			BlockRestartUI: blockRestartUI,
			NetworkSwitch: networkToManager,
			InitiateShutdownCh: initiateShutdownCh,
			TriggerMithril: triggerMithril,
		}, httpapi.CommChannels {
			SwitchNetwork: networkFromHttp,
			SwitchedNetwork: networkToHttp,
			ServiceUpdate: serviceUpdateToHttp,
		}
	}()

	// XXX: os.Interrupt is the regular SIGINT on Unix, but also something rare on Windows
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGQUIT)

	go func(){
		alreadySignaled := false
		for sig := range sigCh {
			if !alreadySignaled {
				alreadySignaled = true
				fmt.Fprintf(os.Stderr, "%s[%d]: got signal (%s), will shutdown...\n",
					OurLogPrefix, os.Getpid(), sig)
				commUI.InitiateShutdownCh <- struct{}{}
			} else {
				fmt.Fprintf(os.Stderr, "%s[%d]: got another signal (%s), but already in shutdown\n",
					OurLogPrefix, os.Getpid(), sig)
			}
		}
	}()

	go func(){ for {
		err := httpapi.Run(appConfig, commHttp, networks)
		fmt.Fprintf(os.Stderr, "%s[%d]: HTTP server failed: %v\n",
			OurLogPrefix, os.Getpid(), err)
		time.Sleep(1 * time.Second)
	}}()

	mithrilCachePort := -1
	if (appConfig.ForceMithrilSnapshot.Preview.Digest != ""	||
		appConfig.ForceMithrilSnapshot.Preprod.Digest != ""	||
		appConfig.ForceMithrilSnapshot.Mainnet.Digest != "") {
		mithrilCachePort = getFreeTCPPort()
		go func(){ for {
			err := mithrilcache.Run(appConfig, mithrilCachePort)
			fmt.Fprintf(os.Stderr, "%s[%d]: mithril-cache HTTP server failed: %v\n",
				OurLogPrefix, os.Getpid(), err)
			time.Sleep(1 * time.Second)
		}}()
	}

	wailsApp := wails3_application.New(wails3_application.Options{
		Name:        "blockfrost-platform-desktop",
		Description: "Full-node headless wallet backend with standardized API",
		Services: []wails3_application.Service{},
		Assets: wails3_application.AssetOptions{
			Handler: (func() http.Handler {
				regular := wails3_application.AssetFileServerFS(webUIAssets)
				return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if r.URL.Path == "/web-ui-config.json" {
						w.Header().Set("Content-Type", "application/json")
						json.NewEncoder(w).Encode(map[string]string{
							"api_url": fmt.Sprintf("http://127.0.0.1:%d", appConfig.ApiPort),
						})
					} else {
						regular.ServeHTTP(w, r)
					}
				})
			})(),
		},
		Mac: wails3_application.MacOptions{
			ActivationPolicy: wails3_application.ActivationPolicyAccessory,
			ApplicationShouldTerminateAfterLastWindowClosed: false,
		},
		Windows: wails3_application.WindowsOptions{
			DisableQuitOnLastWindowClosed: true,
			WebviewUserDataPath: ourpaths.WorkDir,
			WebviewBrowserPath: ourpaths.LibexecDir + sep + "webview2",
		},
		Linux: wails3_application.LinuxOptions{
			DisableQuitOnLastWindowClosed: true,
			ProgramName: "blockfrost-platform-desktop",
		},
	})

	// Window manager:
	openURLInWebUI := make(chan string)
	go func() {
		var currentlyOpenWindow *wails3_application.WebviewWindow
		currentUrl := ""
		for nextUrl := range openURLInWebUI {
			if currentlyOpenWindow != nil {
				if currentUrl != nextUrl {  // one less flicker
					currentlyOpenWindow.SetURL(nextUrl)
				}
			} else {
				currentlyOpenWindow = wailsApp.NewWebviewWindowWithOptions(wails3_application.WebviewWindowOptions{
					Title: "blockfrost-platform-desktop",
					Hidden: false,
					ShouldClose: func(window *wails3_application.WebviewWindow) bool {
						// window.SetURL("about:blank")  // decrease resource usage, a temporary solution
						// window.Hide()
						currentlyOpenWindow = nil
						currentUrl = ""
						setAccessoryActivationPolicyOnDarwin()
						return true
					},
					Mac: wails3_application.MacWindow{
						InvisibleTitleBarHeight: 50,
						Backdrop: wails3_application.MacBackdropTranslucent,
						TitleBar: wails3_application.MacTitleBarHiddenInset,
					},
					BackgroundColour: wails3_application.NewRGB(0xff, 0xff, 0xff),
					// Beware, on Linux the root is "wails://localhost/", on Windows it’s "http://wails.localhost/".
					URL: nextUrl,
				})
			}
			setRegularActivationPolicyOnDarwin()
			activateThisAppOnDarwin()
			currentUrl = nextUrl
		}
	}()

	// XXX: Both macOS and Windows require that UI happens on the main thread.
	// XXX: On macOS both wails.Quit and systray.Quit call [NSApp terminate:nil], which is a hard exit,
	// and Go’s deferred functions won’t run. Therefore wailsApp.Quit() has to be the last thing we call.
	go func() {
		defer func(){
			fmt.Printf("%s[%d]: all good, exiting\n", OurLogPrefix, os.Getpid())
			wailsApp.Quit()
			if runtime.GOOS == "windows" {
				// Otherwise it won’t quit on Windows… Maybe investigate why?
				systray.Quit()
			}
		}()
		manageChildren(commManager, appConfig, mithrilCachePort)
	}()

	systraySetup := func() {
		showWebUI := func(url string) {
			openURLInWebUI <- url
			// window.SetURL(url)
			// window.Show()
		}
		systray.Register(ui.SetupTray(commUI, logFile, networks, appConfig, showWebUI), nil)
	}

	if runtime.GOOS == "windows" {
		// On Windows, `mainthread.Schedule` doesn’t yet work before `systray.Register`,
		// and we have to register systray *before* running the Wails app.
		systraySetup()
	} else {
		// On Linux/Darwin, we have to register it *after* the Wails app is started.
		wailsApp.On(wails3_events.Common.ApplicationStarted, func(event *wails3_application.Event) {
			// Sometimes it’s too early to run directly on Linux (Gtk), so let’s schedule on the next event loop iteration:
			mainthread.Schedule(systraySetup)
		})
	}

	err = wailsApp.Run()
	if err != nil {
		fmt.Printf("%s[%d]: fatal WebView error: %v\n", OurLogPrefix, os.Getpid(), err)
		os.Exit(1)
	}
}

type CommChannels_Manager struct {
	ServiceUpdate        chan<- t.ServiceStatus
	BlockRestartUI       chan<- bool

	NetworkSwitch        <-chan string
	InitiateShutdownCh   <-chan struct{}
	TriggerMithril       <-chan struct{}
}

func logSystemHealth() {
	ourPrefix := fmt.Sprintf("%s[%d]", OurLogPrefix, os.Getpid())

	memInfo, err := mem.VirtualMemory()
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: RAM err: %s\n", ourPrefix, err)
	}

	fmt.Printf("%s: memory: %.2fGi total, %.2fGi free\n", ourPrefix,
		float64(memInfo.Total) / (1024.0 * 1024.0 * 1024.0),
		float64(memInfo.Free) / (1024.0 * 1024.0 * 1024.0))

	avgStat, err := load.Avg()
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: load err: %s\n", ourPrefix, err)
	}

	fmt.Printf("%s: load average: %.2f, %.2f, %.2f\n", ourPrefix,
		avgStat.Load1, avgStat.Load5, avgStat.Load15)
}

// A map from network magic to name
func readAvailableNetworks() (map[t.NetworkMagic]string, error) {
	rv := map[t.NetworkMagic]string{}
	sep := string(filepath.Separator)
	names, err := readDirAsStrings(ourpaths.NetworkConfigDir)
	if err != nil { return nil, err }
	for _, name := range names {
		configFile := ourpaths.NetworkConfigDir + sep + name + sep + "cardano-node" + sep + "config.json"

		configBytes, err := ioutil.ReadFile(configFile)
		var config map[string]interface{}
		err = json.Unmarshal(configBytes, &config)
		if err != nil { return nil, err }

		byronFile := config["ByronGenesisFile"].(string)
		if !filepath.IsAbs(byronFile) {
			byronFile = filepath.Join(filepath.Dir(configFile), byronFile)
		}

		byronBytes, err := ioutil.ReadFile(byronFile)
		var byron map[string]interface{}
		err = json.Unmarshal(byronBytes, &byron)
		if err != nil { return nil, err }

		magic := t.NetworkMagic(int(
			byron["protocolConsts"].(map[string]interface{})["protocolMagic"].(float64)))

		rv[magic] = name
	}
	return rv, nil
}

func readDirAsStrings(dirPath string) ([]string, error) {
	files, err := ioutil.ReadDir(dirPath)
	if err != nil { return nil, err }
	rv := []string{}
	for _, file := range files {
		name := file.Name()
		if name == "." || name == ".." {
			continue
		}
		rv = append(rv, name)
	}
	return rv, nil
}
