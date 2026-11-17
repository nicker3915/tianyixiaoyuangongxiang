using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("校园网共享助手")]
[assembly: AssemblyVersion("1.4.2.0")]
[assembly: AssemblyFileVersion("1.4.2.0")]
[assembly: AssemblyProduct("校园网共享助手")]
[assembly: AssemblyDescription("Wi-Fi 与有线共享、网络检测及可恢复卸载")]

internal static class Program
{
    private static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;

    private static int Fail(string mode, int code, string reason)
    {
        try
        {
            string directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "GDPortalShare");
            Directory.CreateDirectory(directory);
            string log = Path.Combine(directory, "launcher.log");
            if (File.Exists(log) && new FileInfo(log).Length > 65536)
                File.Delete(log);
            File.AppendAllText(log, DateTimeOffset.Now.ToString("o") +
                " [" + mode + "] exit=" + code + " " + reason + Environment.NewLine);
        }
        catch { }
        if (mode == "panel" || mode == "firstrun")
        {
            MessageBox.Show(
                reason + "\n\n程序所在文件夹\n" + Root +
                "\n\n请重新运行安装包修复安装。若文件被安全软件隔离，请先查看保护历史中的具体提示。",
                "校园网共享助手 · 启动未完成",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        return code;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        string mode = args.Length == 0 ? "panel" : args[0];
        if (args.Length > 1) return Fail(mode, 64, "启动参数不正确。");
        if (mode == "cleanup")
        {
            try
            {
                string source = Path.Combine(Root, "校园网共享助手-清理与卸载.exe");
                if (!File.Exists(source))
                    return Fail("panel", 66, "清理工具缺失。请使用发布目录中的独立清理工具，或重新下载完整安装包。");
                string temporary = Path.Combine(Path.GetTempPath(), "GDPortalShare-Cleanup-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(temporary);
                string helper = Path.Combine(temporary, Path.GetFileName(source));
                File.Copy(source, helper, false);
                Process.Start(new ProcessStartInfo
                {
                    FileName = helper,
                    Arguments = "/TARGET=\"" + Root.TrimEnd(Path.DirectorySeparatorChar) + "\"",
                    WorkingDirectory = temporary,
                    UseShellExecute = true
                });
                return 0;
            }
            catch (Exception error)
            {
                return Fail("panel", 70, "无法打开独立清理工具（" + error.GetType().Name + "）。");
            }
        }
        string script;
        string extraArguments = "";
        if (mode == "watch") script = "Watch-CampusNetwork.ps1";
        else if (mode == "startup") script = "Start-CampusNetwork.ps1";
        else if (mode == "panel") script = "Panel.ps1";
        else if (mode == "firstrun")
        {
            script = "Panel.ps1";
            extraArguments = " -FirstRun";
        }
        else return Fail("panel", 64, "无法识别启动参数。请直接双击校园网共享助手.exe。");

        try
        {
            string scriptPath = Path.Combine(Root, script);
            if (!File.Exists(scriptPath))
                return Fail(mode, 66, "缺少程序组件 " + script + "。请将程序文件保留在同一安装目录。");
            string powerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            var info = new ProcessStartInfo
            {
                FileName = powerShell,
                Arguments = "-NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" +
                    scriptPath + "\"" + extraArguments,
                WorkingDirectory = Root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (Process child = Process.Start(info))
            {
                if (child == null) return Fail(mode, 70, "Windows 未能启动程序组件。");
                // The authentication worker outlives its setup script. Do not create
                // redirected pipes: inherited worker handles would keep async reads
                // open and make WaitForExit wait beyond the script's actual exit.
                child.WaitForExit();
                if (child.ExitCode != 0)
                    return Fail(mode, child.ExitCode, "程序组件未能正常运行，退出码 " + child.ExitCode + "。");
                return 0;
            }
        }
        catch (Exception error)
        {
            return Fail(mode, 70, "启动失败（" + error.GetType().Name + "）。");
        }
    }
}
