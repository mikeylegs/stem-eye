# A stand-in for UxPlay: a full-screen black window titled like an AirPlay receiver, showing djay frames (letterboxed 4:3) at 15 a second.
# Writes the time the first frame was shown (epoch ms) to -Start.
param([string]$Frames, [string]$Start, [int]$Fps = 15)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.IO; using System.Drawing; using System.Windows.Forms; using System.Diagnostics;
public class FakeAirPlay : Form {
  string[] files; PictureBox pb = new PictureBox(); Timer tm = new Timer(); Stopwatch sw = new Stopwatch(); string start; int fps; int shown = -1;
  public FakeAirPlay(string dir, string startFile, int f) { files = Directory.GetFiles(dir, "*.jpg"); Array.Sort(files, StringComparer.Ordinal); start = startFile; fps = f;
    Text = "UxPlay AirPlay test"; BackColor = Color.Black; FormBorderStyle = FormBorderStyle.None; WindowState = FormWindowState.Maximized; TopMost = true;
    pb.Dock = DockStyle.Fill; pb.SizeMode = PictureBoxSizeMode.Zoom; pb.BackColor = Color.Black; Controls.Add(pb);
    tm.Interval = 10; tm.Tick += delegate { Step(); }; Shown += delegate { sw.Start(); tm.Start(); }; }
  void Step() { int i = (int)Math.Floor(sw.Elapsed.TotalSeconds * fps); if (i >= files.Length) { Close(); return; } if (i == shown) return;
    Image old = pb.Image; pb.Image = Image.FromFile(files[i]); pb.Refresh(); if (old != null) old.Dispose();
    if (shown < 0) File.WriteAllText(start, ((DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds - sw.Elapsed.TotalMilliseconds).ToString("0", System.Globalization.CultureInfo.InvariantCulture));
    shown = i; }
}
'@
[System.Windows.Forms.Application]::Run((New-Object FakeAirPlay($Frames, $Start, $Fps)))
