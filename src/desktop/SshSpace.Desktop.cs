using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

[assembly: AssemblyTitle("SSH Space")]
[assembly: AssemblyDescription("SSH Space desktop control plane")]
[assembly: AssemblyProduct("SSH Space Desktop")]
[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]

internal static class Program
{
    private const string RuntimeVersion = "1.0.2592.51";
    private static Mutex instanceMutex;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetDllDirectory(string pathName);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDPIAware();

    [STAThread]
    private static int Main()
    {
        ConfigureDpiAwareness();
        bool createdNew;
        instanceMutex = new Mutex(true, @"Local\SSHSpaceDesktop", out createdNew);
        if (!createdNew)
        {
            MessageBox.Show("SSH Space desktop is already running.", "SSH Space",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }

        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            try
            {
                string previousBuild = Path.Combine(root, "build", "SSH Space.previous.exe");
                if (File.Exists(previousBuild)) File.Delete(previousBuild);
            }
            catch { }
            if (!File.Exists(Path.Combine(root, "app", "server.ps1")))
            {
                throw new FileNotFoundException("app\\server.ps1 is missing from the SSH Space application directory.");
            }

            string runtimeDirectory = RuntimeBundle.Extract(RuntimeVersion);
            AppDomain.CurrentDomain.AssemblyResolve += delegate(object sender, ResolveEventArgs args)
            {
                string name = new AssemblyName(args.Name).Name + ".dll";
                string candidate = Path.Combine(runtimeDirectory, name);
                return File.Exists(candidate) ? Assembly.LoadFrom(candidate) : null;
            };
            SetDllDirectory(runtimeDirectory);

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SshSpaceWindow(root));
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "SSH Space",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            if (instanceMutex != null)
            {
                instanceMutex.ReleaseMutex();
                instanceMutex.Dispose();
            }
        }
    }

    private static void ConfigureDpiAwareness()
    {
        try
        {
            if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return;
        }
        catch (EntryPointNotFoundException) { }
        try { SetProcessDPIAware(); } catch { }
    }
}

internal static class RuntimeBundle
{
    private const string CoreResource = "SshSpace.Resources.WebView2.Core";
    private const string WinFormsResource = "SshSpace.Resources.WebView2.WinForms";
    private const string LoaderX64Resource = "SshSpace.Resources.WebView2.Loader.x64";
    private const string LoaderX86Resource = "SshSpace.Resources.WebView2.Loader.x86";

    internal static string Extract(string version)
    {
        string architecture = Environment.Is64BitProcess ? "x64" : "x86";
        string directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SSH Space", "runtime", version, architecture);
        Directory.CreateDirectory(directory);

        WriteResource(CoreResource, Path.Combine(directory, "Microsoft.Web.WebView2.Core.dll"));
        WriteResource(WinFormsResource, Path.Combine(directory, "Microsoft.Web.WebView2.WinForms.dll"));
        WriteResource(Environment.Is64BitProcess ? LoaderX64Resource : LoaderX86Resource,
            Path.Combine(directory, "WebView2Loader.dll"));
        return directory;
    }

    private static void WriteResource(string resourceName, string destination)
    {
        if (File.Exists(destination) && new FileInfo(destination).Length > 1024)
        {
            return;
        }

        Assembly assembly = Assembly.GetExecutingAssembly();
        using (Stream source = assembly.GetManifestResourceStream(resourceName))
        {
            if (source == null)
            {
                throw new InvalidOperationException("Embedded desktop runtime is incomplete: " + resourceName);
            }
            using (FileStream output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                source.CopyTo(output);
            }
        }
    }
}

internal sealed class SshSpaceWindow : Form
{
    private readonly string root;
    private readonly WebView2 webView;
    private readonly Label status;
    private Process ownedServer;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute,
        ref int value, int valueSize);

    internal SshSpaceWindow(string workspaceRoot)
    {
        root = workspaceRoot;
        Text = "SSH Space";
        BackColor = Color.FromArgb(7, 9, 8);
        ForeColor = Color.FromArgb(242, 245, 241);
        ClientSize = new Size(1400, 880);
        MinimumSize = new Size(900, 640);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.Sizable;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

        webView = new WebView2();
        webView.Dock = DockStyle.Fill;
        webView.Visible = false;
        webView.DefaultBackgroundColor = Color.FromArgb(7, 9, 8);

        status = new Label();
        status.Dock = DockStyle.Fill;
        status.TextAlign = ContentAlignment.MiddleCenter;
        status.Font = new Font("Consolas", 11F, FontStyle.Bold);
        status.ForeColor = Color.FromArgb(156, 248, 199);
        status.BackColor = Color.FromArgb(7, 9, 8);
        status.Text = "SSH SPACE / INITIALIZING CONTROL PLANE";

        Controls.Add(webView);
        Controls.Add(status);
        Shown += async delegate { await InitializeAsync(); };
        FormClosing += delegate { StopOwnedServer(); };
    }

    protected override void OnHandleCreated(EventArgs eventArgs)
    {
        base.OnHandleCreated(eventArgs);
        int enabled = 1;
        if (DwmSetWindowAttribute(Handle, 20, ref enabled, sizeof(int)) != 0)
        {
            DwmSetWindowAttribute(Handle, 19, ref enabled, sizeof(int));
        }
    }

    private async Task InitializeAsync()
    {
        try
        {
            status.Text = "SSH SPACE / STARTING LOCAL SERVICE";
            ServerHandle handle = await Task.Run(() => LocalServer.GetOrStart(root));
            ownedServer = handle.Process;

            status.Text = "SSH SPACE / PREPARING DESKTOP VIEW";
            string userData = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SSH Space", "WebView2");
            CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(null, userData);
            await webView.EnsureCoreWebView2Async(environment);

            webView.CoreWebView2.Settings.AreDevToolsEnabled = false;
            webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
            webView.CoreWebView2.Settings.IsZoomControlEnabled = true;
            webView.CoreWebView2.NewWindowRequested += delegate(object sender, CoreWebView2NewWindowRequestedEventArgs args)
            {
                args.Handled = true;
                if (Uri.IsWellFormedUriString(args.Uri, UriKind.Absolute))
                {
                    Process.Start(args.Uri);
                }
            };
            webView.NavigationCompleted += delegate(object sender, CoreWebView2NavigationCompletedEventArgs args)
            {
                if (args.IsSuccess)
                {
                    status.Visible = false;
                    webView.Visible = true;
                    webView.Focus();
                }
                else
                {
                    ShowFailure("The desktop view could not load the local console.");
                }
            };
            webView.Source = new Uri(handle.Url);
        }
        catch (Exception exception)
        {
            ShowFailure(exception.Message);
        }
    }

    private void ShowFailure(string message)
    {
        status.Visible = true;
        status.Text = "SSH SPACE / START FAILED\r\n\r\n" + message;
        status.ForeColor = Color.FromArgb(255, 115, 121);
    }

    private void StopOwnedServer()
    {
        if (ownedServer == null)
        {
            return;
        }
        try
        {
            if (!ownedServer.HasExited)
            {
                ownedServer.Kill();
                ownedServer.WaitForExit(1500);
            }
        }
        catch { }
        finally
        {
            ownedServer.Dispose();
            ownedServer = null;
        }
    }
}

internal sealed class ServerHandle
{
    internal string Url { get; set; }
    internal Process Process { get; set; }
}

internal static class LocalServer
{
    private const int FirstPort = 8787;
    private const int LastPort = 8807;

    internal static ServerHandle GetOrStart(string root)
    {
        for (int port = FirstPort; port <= LastPort; port++)
        {
            if (IsSshSpace(port))
            {
                return new ServerHandle { Url = Url(port) };
            }
        }

        int selectedPort = -1;
        for (int port = FirstPort; port <= LastPort; port++)
        {
            if (IsPortAvailable(port))
            {
                selectedPort = port;
                break;
            }
        }
        if (selectedPort < 0)
        {
            throw new InvalidOperationException("No free local port is available in the range 8787-8807.");
        }

        string powerShell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(powerShell))
        {
            throw new FileNotFoundException("Windows PowerShell is not available on this computer.");
        }

        string script = Path.Combine(root, "app", "server.ps1").Replace("'", "''");
        string childCode = "& '" + script + "' -Port " + selectedPort + " -NoBrowser";
        string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(childCode));
        Process process = Process.Start(new ProcessStartInfo
        {
            FileName = powerShell,
            Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand " + encoded,
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        });

        for (int attempt = 0; attempt < 100; attempt++)
        {
            for (int port = selectedPort; port <= LastPort; port++)
            {
                if (IsSshSpace(port))
                {
                    return new ServerHandle { Url = Url(port), Process = process };
                }
            }
            if (process.HasExited)
            {
                break;
            }
            Thread.Sleep(100);
        }

        try { if (!process.HasExited) process.Kill(); } catch { }
        process.Dispose();
        throw new InvalidOperationException("The local SSH Space service did not start.");
    }

    private static string Url(int port)
    {
        return "http://127.0.0.1:" + port + "/";
    }

    private static bool IsSshSpace(int port)
    {
        try
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(Url(port));
            request.Timeout = 250;
            request.ReadWriteTimeout = 250;
            request.Proxy = null;
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (StreamReader reader = new StreamReader(response.GetResponseStream()))
            {
                string html = reader.ReadToEnd();
                return response.StatusCode == HttpStatusCode.OK &&
                    html.Contains("<title>SSH Space</title>") &&
                    html.Contains("name=\"api-token\"");
            }
        }
        catch
        {
            return false;
        }
    }

    private static bool IsPortAvailable(int port)
    {
        System.Net.Sockets.TcpListener listener =
            new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
        try
        {
            listener.Start();
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            try { listener.Stop(); } catch { }
        }
    }
}
