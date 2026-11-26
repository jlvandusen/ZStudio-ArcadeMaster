<#
  ArcadeMaster visual kit - shared by Show-ToolScreen.ps1 (live tool pages) and New-ToolsArt.ps1 (Tools list art).
  Dot-source it. Provides [AmDraw] (GDI+ icons, cards, switches, checks, bars) and [AmJoyLive] (winmm joystick read).
#>
if (-not ('AmDraw' -as [type])) {
Add-Type -AssemblyName System.Drawing
$amVisualSrc = @'
using System; using System.Drawing; using System.Drawing.Drawing2D; using System.Runtime.InteropServices; using System.Text;

public static class AmPal {
  public static readonly Color Bg = Color.FromArgb(8, 9, 14), Card = Color.FromArgb(20, 22, 31), Card2 = Color.FromArgb(28, 31, 44);
  public static readonly Color Magenta = Color.FromArgb(255, 47, 160), Cyan = Color.FromArgb(46, 200, 255), Amber = Color.FromArgb(255, 176, 0);
  public static readonly Color Violet = Color.FromArgb(123, 92, 255), Green = Color.FromArgb(61, 220, 132), Red = Color.FromArgb(255, 90, 90);
  public static readonly Color Text = Color.FromArgb(230, 233, 240), Dim = Color.FromArgb(154, 163, 178), Faint = Color.FromArgb(60, 66, 84);
  public static Color A(Color c, int a) { return Color.FromArgb(Math.Max(0, Math.Min(255, a)), c); }
  public static Color Hex(string h) { h = h.TrimStart('#'); return Color.FromArgb(Convert.ToInt32(h.Substring(0, 2), 16), Convert.ToInt32(h.Substring(2, 2), 16), Convert.ToInt32(h.Substring(4, 2), 16)); }
}

public static class AmDraw {
  public static void Hq(Graphics g) { g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit; g.PixelOffsetMode = PixelOffsetMode.HighQuality; g.InterpolationMode = InterpolationMode.HighQualityBicubic; }

  public static GraphicsPath Round(RectangleF r, float rad) {
    var p = new GraphicsPath(); float d = Math.Max(1f, Math.Min(rad * 2, Math.Min(r.Width, r.Height)));
    p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
    p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90); p.CloseFigure(); return p;
  }
  // dark card with an accent border and soft glow
  public static void Card(Graphics g, RectangleF r, Color accent, float rad, bool glow) {
    if (glow) for (int i = 3; i >= 1; i--) using (var gp = Round(RectangleF.Inflate(r, i * 3, i * 3), rad + i * 3)) using (var pen = new Pen(AmPal.A(accent, 22 * (4 - i)), 3)) g.DrawPath(pen, gp);
    using (var p = Round(r, rad)) {
      using (var b = new LinearGradientBrush(r, AmPal.Card2, AmPal.Card, 90f)) g.FillPath(b, p);
      using (var pen = new Pen(AmPal.A(accent, 200), Math.Max(2f, r.Height / 160f))) g.DrawPath(pen, p);
    }
  }
  public static void Text(Graphics g, string s, Font f, Color c, RectangleF r, StringAlignment h, StringAlignment v) {
    using (var sf = new StringFormat { Alignment = h, LineAlignment = v, Trimming = StringTrimming.EllipsisCharacter }) using (var b = new SolidBrush(c)) g.DrawString(s, f, b, r, sf);
  }
  // neon outlined text (title style)
  public static void Neon(Graphics g, string s, FontFamily ff, FontStyle st, float px, Color c, RectangleF r, StringAlignment h) {
    using (var gp = new GraphicsPath()) using (var sf = new StringFormat { Alignment = h, LineAlignment = StringAlignment.Center }) {
      gp.AddString(s, ff, (int)st, px, r, sf);
      foreach (var w in new[] { px / 4.5f, px / 8f }) using (var pen = new Pen(AmPal.A(c, w > px / 6 ? 40 : 90), w) { LineJoin = LineJoin.Round }) g.DrawPath(pen, gp);
      using (var b = new LinearGradientBrush(new PointF(0, r.Top), new PointF(0, r.Bottom + 1), Color.White, c)) g.FillPath(b, gp);
    }
  }
  public static void Bar(Graphics g, RectangleF r, float v, Color c) {
    v = Math.Max(0, Math.Min(1, v));
    using (var p = Round(r, r.Height / 2)) using (var b = new SolidBrush(AmPal.Faint)) g.FillPath(b, p);
    if (v > 0.005f) { var f = new RectangleF(r.X, r.Y, Math.Max(r.Height, r.Width * v), r.Height); using (var p = Round(f, r.Height / 2)) using (var b = new LinearGradientBrush(f, AmPal.A(c, 170), c, 0f)) g.FillPath(b, p); }
  }
  // ON/OFF pill switch
  public static void Toggle(Graphics g, RectangleF r, bool on, Color accent, Font f) { ToggleAt(g, r, on ? 1f : 0f, accent, f); }
  // pos 0 = OFF .. 1 = ON (animate the knob by passing intermediate values)
  public static void ToggleAt(Graphics g, RectangleF r, float pos, Color accent, Font f) {
    pos = Math.Max(0, Math.Min(1, pos)); bool on = pos >= 0.5f;
    var c = on ? accent : AmPal.Faint;
    using (var p = Round(r, r.Height / 2)) { using (var b = new SolidBrush(on ? AmPal.A(accent, 70) : AmPal.Card)) g.FillPath(b, p); using (var pen = new Pen(c, r.Height / 14)) g.DrawPath(pen, p); }
    float k = r.Height * 0.78f, m = (r.Height - k) / 2; var kr = new RectangleF(r.X + m + (r.Width - 2 * m - k) * pos, r.Y + m, k, k);
    if (on) for (int i = 3; i >= 1; i--) using (var b = new SolidBrush(AmPal.A(accent, 30))) g.FillEllipse(b, RectangleF.Inflate(kr, i * k / 14, i * k / 14));
    using (var b = new SolidBrush(on ? Color.White : AmPal.Dim)) g.FillEllipse(b, kr);
    if (f != null) Text(g, on ? "ON" : "OFF", f, on ? Color.White : AmPal.Dim, on ? new RectangleF(r.X, r.Y, r.Width - k - m, r.Height) : new RectangleF(r.X + k + m, r.Y, r.Width - k - m, r.Height), StringAlignment.Center, StringAlignment.Center);
  }
  // state: 0 pending, 1 running (phase = spinner angle), 2 ok, 3 failed
  public static void Check(Graphics g, RectangleF r, int state, float phase) {
    float w = Math.Max(2, r.Width / 9);
    if (state == 0) { using (var pen = new Pen(AmPal.Faint, w)) g.DrawEllipse(pen, RectangleF.Inflate(r, -w, -w)); return; }
    if (state == 1) { using (var pen = new Pen(AmPal.Faint, w)) g.DrawEllipse(pen, RectangleF.Inflate(r, -w, -w)); using (var pen = new Pen(AmPal.Cyan, w) { StartCap = LineCap.Round, EndCap = LineCap.Round }) g.DrawArc(pen, RectangleF.Inflate(r, -w, -w), phase, 100); return; }
    var c = state == 2 ? AmPal.Green : AmPal.Red;
    using (var b = new SolidBrush(c)) g.FillEllipse(b, r);
    using (var pen = new Pen(AmPal.Bg, w * 1.1f) { StartCap = LineCap.Round, EndCap = LineCap.Round }) {
      if (state == 2) g.DrawLines(pen, new[] { new PointF(r.X + r.Width * .27f, r.Y + r.Height * .52f), new PointF(r.X + r.Width * .44f, r.Y + r.Height * .69f), new PointF(r.X + r.Width * .74f, r.Y + r.Height * .34f) });
      else { g.DrawLine(pen, r.X + r.Width * .32f, r.Y + r.Height * .32f, r.X + r.Width * .68f, r.Y + r.Height * .68f); g.DrawLine(pen, r.X + r.Width * .68f, r.Y + r.Height * .32f, r.X + r.Width * .32f, r.Y + r.Height * .68f); }
    }
  }

  static Pen P(Color c, float w) { return new Pen(c, w) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round }; }
  static RectangleF Sq(RectangleF r) { float s = Math.Min(r.Width, r.Height); return new RectangleF(r.X + (r.Width - s) / 2, r.Y + (r.Height - s) / 2, s, s); }

  // icon by kind; live = kind-specific live value (wheel angle in degrees, pedal/handbrake travel 0..1, spinner phase)
  public static void Icon(Graphics g, string kind, RectangleF box, Color c, float live) {
    var r = Sq(box); float s = r.Width, w = Math.Max(2, s / 14); float x = r.X, y = r.Y;
    var st = g.Save();
    switch ((kind ?? "").ToLowerInvariant()) {
      case "wheel": case "setup": {
        g.TranslateTransform(x + s / 2, y + s / 2); g.RotateTransform(live);
        float R = s * .44f;
        using (var pen = P(c, s / 11)) g.DrawEllipse(pen, -R, -R, 2 * R, 2 * R);
        using (var pen = P(AmPal.A(c, 200), s / 13)) { g.DrawLine(pen, -R, 0, -s * .1f, 0); g.DrawLine(pen, R, 0, s * .1f, 0); g.DrawLine(pen, 0, s * .1f, 0, R); }
        using (var b = new SolidBrush(c)) g.FillEllipse(b, -s * .12f, -s * .12f, s * .24f, s * .24f);
        using (var pen = P(AmPal.Magenta, s / 11)) g.DrawArc(pen, -R, -R, 2 * R, 2 * R, 262, 16);
        break; }
      case "pedals": {
        for (int i = 0; i < 3; i++) {
          float pw = s * .2f, ph = s * (i == 2 ? .62f : .5f), px = x + s * .1f + i * s * .3f, py = y + s * .92f - ph;
          float t = i == 2 ? live : 0; py += t * ph * .25f;
          using (var p = Round(new RectangleF(px, py, pw, ph), pw / 3)) { using (var b = new SolidBrush(AmPal.A(c, 60))) g.FillPath(b, p); using (var pen = P(c, w)) g.DrawPath(pen, p); }
          using (var pen = P(AmPal.A(c, 140), w / 2)) for (int k = 1; k < 4; k++) g.DrawLine(pen, px + pw * .25f, py + ph * k / 4f, px + pw * .75f, py + ph * k / 4f);
        }
        break; }
      case "handbrake": {
        using (var pen = P(AmPal.A(c, 160), w)) g.DrawRectangle(pen, x + s * .2f, y + s * .78f, s * .6f, s * .14f);
        g.TranslateTransform(x + s * .32f, y + s * .82f); g.RotateTransform(-35 - live * 35);
        using (var pen = P(c, s / 9)) g.DrawLine(pen, 0, 0, s * .62f, 0);
        using (var b = new SolidBrush(c)) g.FillEllipse(b, s * .52f, -s * .09f, s * .2f, s * .18f);
        break; }
      case "shifter": {
        using (var pen = P(AmPal.A(c, 120), w / 1.5f)) { g.DrawLine(pen, x + s * .2f, y + s * .3f, x + s * .2f, y + s * .7f); g.DrawLine(pen, x + s * .5f, y + s * .3f, x + s * .5f, y + s * .7f); g.DrawLine(pen, x + s * .8f, y + s * .3f, x + s * .8f, y + s * .7f); g.DrawLine(pen, x + s * .2f, y + s * .5f, x + s * .8f, y + s * .5f); }
        using (var pen = P(c, w)) g.DrawLine(pen, x + s * .5f, y + s * .5f, x + s * .5f, y + s * .3f);
        using (var b = new SolidBrush(c)) g.FillEllipse(b, x + s * .37f, y + s * .08f, s * .26f, s * .26f);
        break; }
      case "gamepad": {
        var body = new RectangleF(x + s * .05f, y + s * .28f, s * .9f, s * .48f);
        using (var p = Round(body, s * .2f)) { using (var b = new SolidBrush(AmPal.A(c, 50))) g.FillPath(b, p); using (var pen = P(c, w)) g.DrawPath(pen, p); }
        using (var pen = P(c, w)) { g.DrawLine(pen, x + s * .2f, y + s * .52f, x + s * .36f, y + s * .52f); g.DrawLine(pen, x + s * .28f, y + s * .44f, x + s * .28f, y + s * .6f); }
        using (var b = new SolidBrush(c)) foreach (var d in new[] { new PointF(.7f, .44f), new PointF(.78f, .52f), new PointF(.62f, .52f), new PointF(.7f, .6f) }) g.FillEllipse(b, x + s * d.X - s * .035f, y + s * d.Y - s * .035f, s * .07f, s * .07f);
        break; }
      case "joystick": case "flight": case "stick": {
        using (var p = Round(new RectangleF(x + s * .18f, y + s * .74f, s * .64f, s * .18f), s * .05f)) { using (var b = new SolidBrush(AmPal.A(c, 60))) g.FillPath(b, p); using (var pen = P(c, w)) g.DrawPath(pen, p); }
        g.TranslateTransform(x + s * .5f, y + s * .76f); g.RotateTransform(live);
        using (var pen = P(c, s / 12)) g.DrawLine(pen, 0, 0, 0, -s * .48f);
        using (var b = new SolidBrush(AmPal.Magenta)) g.FillEllipse(b, -s * .13f, -s * .68f, s * .26f, s * .26f);
        break; }
      case "gun": case "lightgun": {
        var pts = new[] { new PointF(.06f, .3f), new PointF(.92f, .3f), new PointF(.92f, .46f), new PointF(.5f, .46f), new PointF(.46f, .5f), new PointF(.5f, .86f), new PointF(.3f, .86f), new PointF(.26f, .5f), new PointF(.06f, .46f) };
        var pp = new PointF[pts.Length]; for (int i = 0; i < pts.Length; i++) pp[i] = new PointF(x + s * pts[i].X, y + s * pts[i].Y);
        using (var b = new SolidBrush(AmPal.A(c, 60))) g.FillPolygon(b, pp); using (var pen = P(c, w)) g.DrawPolygon(pen, pp);
        using (var pen = P(c, w * .8f)) g.DrawArc(pen, x + s * .38f, y + s * .42f, s * .16f, s * .2f, 0, 180);
        break; }
      case "trackball": {
        using (var p = Round(new RectangleF(x + s * .08f, y + s * .5f, s * .84f, s * .38f), s * .08f)) { using (var b = new SolidBrush(AmPal.A(c, 40))) g.FillPath(b, p); using (var pen = P(c, w)) g.DrawPath(pen, p); }
        var ball = new RectangleF(x + s * .24f, y + s * .14f, s * .52f, s * .52f);
        using (var b = new LinearGradientBrush(ball, Color.White, c, 45f)) g.FillEllipse(b, ball);
        break; }
      case "power": case "restart": {
        // power symbol: an open ring with a bar through the gap; "restart" adds an arrow head on the ring's end
        using (var pen = P(c, w)) {
          g.DrawArc(pen, x + s * .16f, y + s * .2f, s * .68f, s * .68f, -60f, 300f);
          g.DrawLine(pen, x + s * .5f, y + s * .1f, x + s * .5f, y + s * .5f);
          if (kind == "restart") { g.DrawLine(pen, x + s * .67f, y + s * .27f, x + s * .79f, y + s * .2f); g.DrawLine(pen, x + s * .67f, y + s * .27f, x + s * .73f, y + s * .39f); }
        }
        break; }      case "touch": {
        using (var p = Round(new RectangleF(x + s * .1f, y + s * .1f, s * .8f, s * .58f), s * .06f)) using (var pen = P(c, w)) g.DrawPath(pen, p);
        using (var b = new SolidBrush(AmPal.A(c, 90))) g.FillEllipse(b, x + s * .38f, y + s * .28f, s * .24f, s * .24f);
        using (var pen = P(c, s / 9)) g.DrawLine(pen, x + s * .5f, y + s * .42f, x + s * .5f, y + s * .9f);
        break; }
      case "display": case "screen": case "screen2": {
        int n = kind == "screen2" ? 2 : 1;
        for (int i = 0; i < n; i++) {
          float ox = n == 2 ? (i == 0 ? -s * .12f : s * .12f) : 0, oy = n == 2 ? (i == 0 ? -s * .08f : s * .1f) : 0, sc = n == 2 ? .78f : 1f;
          var rr = new RectangleF(x + s * .5f + ox - s * .42f * sc, y + s * .42f + oy - s * .28f * sc, s * .84f * sc, s * .56f * sc);
          using (var p = Round(rr, s * .04f)) { using (var b = new SolidBrush(AmPal.Card)) g.FillPath(b, p); using (var pen = P(i == 1 ? AmPal.Magenta : c, w)) g.DrawPath(pen, p); }
        }
        using (var pen = P(c, w)) { g.DrawLine(pen, x + s * .5f, y + s * .74f, x + s * .5f, y + s * .86f); g.DrawLine(pen, x + s * .3f, y + s * .88f, x + s * .7f, y + s * .88f); }
        break; }
      case "keyboard": {
        using (var p = Round(new RectangleF(x + s * .04f, y + s * .3f, s * .92f, s * .42f), s * .06f)) using (var pen = P(c, w)) g.DrawPath(pen, p);
        using (var b = new SolidBrush(AmPal.A(c, 170))) for (int row = 0; row < 3; row++) for (int col = 0; col < 7; col++) g.FillRectangle(b, x + s * (.12f + col * .11f), y + s * (.38f + row * .1f), s * .07f, s * .06f);
        break; }
      case "mouse": {
        using (var p = Round(new RectangleF(x + s * .28f, y + s * .12f, s * .44f, s * .76f), s * .22f)) using (var pen = P(c, w)) g.DrawPath(pen, p);
        using (var pen = P(c, w)) g.DrawLine(pen, x + s * .5f, y + s * .14f, x + s * .5f, y + s * .38f);
        break; }
      case "ffb": {
        Icon(g, "wheel", new RectangleF(x + s * .16f, y + s * .16f, s * .68f, s * .68f), c, live);
        using (var pen = P(AmPal.A(c, 170), w * .8f)) { g.DrawArc(pen, x, y, s, s, 200, 50); g.DrawArc(pen, x, y, s, s, 290, 50); g.DrawArc(pen, x + s * .06f, y + s * .06f, s * .88f, s * .88f, 20, 50); g.DrawArc(pen, x + s * .06f, y + s * .06f, s * .88f, s * .88f, 110, 50); }
        break; }
      case "perf": {
        var rr = new RectangleF(x + s * .06f, y + s * .14f, s * .88f, s * .88f);
        using (var pen = P(AmPal.Faint, w)) g.DrawArc(pen, rr, 150, 240);
        using (var pen = P(c, w)) g.DrawArc(pen, rr, 150, 170);
        using (var pen = P(AmPal.Red, w)) g.DrawArc(pen, rr, 340, 50);
        g.TranslateTransform(x + s * .5f, y + s * .58f); g.RotateTransform(-130 + 210 * Math.Max(0, Math.Min(1, live)));
        using (var pen = P(Color.White, w * .8f)) g.DrawLine(pen, 0, 0, 0, -s * .36f);
        break; }
      case "shuffle": case "images": {
        for (int i = 2; i >= 0; i--) {
          var rr = new RectangleF(x + s * (.08f + i * .1f), y + s * (.38f - i * .1f), s * .62f, s * .44f);
          using (var p = Round(rr, s * .04f)) { using (var b = new LinearGradientBrush(rr, AmPal.A(i == 0 ? AmPal.Violet : c, 200), AmPal.Card, 60f)) g.FillPath(b, p); using (var pen = P(i == 0 ? Color.White : c, w * .7f)) g.DrawPath(pen, p); }
        }
        break; }
      case "rebuild": case "list": {
        for (int i = 0; i < 4; i++) {
          float ly = y + s * (.16f + i * .2f);
          using (var b = new SolidBrush(i < 3 ? AmPal.Green : AmPal.Faint)) g.FillEllipse(b, x + s * .06f, ly, s * .12f, s * .12f);
          using (var pen = P(i < 3 ? c : AmPal.Faint, w)) g.DrawLine(pen, x + s * .28f, ly + s * .06f, x + s * (.92f - (i % 2) * .18f), ly + s * .06f);
        }
        break; }
      case "repair": case "link": {
        g.TranslateTransform(x + s / 2, y + s / 2); g.RotateTransform(live);
        float R = s * .36f;
        using (var pen = P(c, w)) { g.DrawArc(pen, -R, -R, 2 * R, 2 * R, 20, 140); g.DrawArc(pen, -R, -R, 2 * R, 2 * R, 200, 140); }
        using (var b = new SolidBrush(c)) {
          g.FillPolygon(b, new[] { new PointF(-R - s * .1f, -s * .02f), new PointF(-R + s * .1f, -s * .02f), new PointF(-R, s * .12f) });
          g.FillPolygon(b, new[] { new PointF(R - s * .1f, s * .02f), new PointF(R + s * .1f, s * .02f), new PointF(R, -s * .12f) });
          g.FillEllipse(b, -s * .08f, -s * .08f, s * .16f, s * .16f);
        }
        break; }
      case "detect": case "controllers": {
        Icon(g, "gamepad", new RectangleF(x, y + s * .12f, s * .62f, s * .62f), AmPal.A(c, 160), 0);
        Icon(g, "wheel", new RectangleF(x + s * .38f, y + s * .3f, s * .62f, s * .62f), c, live);
        break; }
      case "wiimote": case "wand": {
        var body = new RectangleF(x + s * .36f, y + s * .04f, s * .28f, s * .92f);
        using (var p = Round(body, s * .08f)) { using (var b = new SolidBrush(AmPal.A(c, 45))) g.FillPath(b, p); using (var pen = P(c, w)) g.DrawPath(pen, p); }
        using (var pen = P(c, w * .8f)) { g.DrawLine(pen, x + s * .44f, y + s * .2f, x + s * .56f, y + s * .2f); g.DrawLine(pen, x + s * .5f, y + s * .14f, x + s * .5f, y + s * .26f); }
        using (var b = new SolidBrush(c)) { g.FillEllipse(b, x + s * .45f, y + s * .33f, s * .1f, s * .1f); g.FillEllipse(b, x + s * .47f, y + s * .7f, s * .06f, s * .06f); g.FillEllipse(b, x + s * .47f, y + s * .8f, s * .06f, s * .06f); }
        break; }
      case "plane": case "jet": {
        // top-down jet: fuselage, swept wings, tailplane
        g.TranslateTransform(x + s / 2, y + s / 2); g.RotateTransform(live);
        var body = new[] { new PointF(0, -s * .46f), new PointF(s * .06f, -s * .3f), new PointF(s * .06f, -s * .06f), new PointF(s * .44f, s * .14f), new PointF(s * .44f, s * .22f), new PointF(s * .06f, s * .12f),
                           new PointF(s * .05f, s * .32f), new PointF(s * .17f, s * .42f), new PointF(s * .17f, s * .47f), new PointF(0, s * .42f), new PointF(-s * .17f, s * .47f), new PointF(-s * .17f, s * .42f),
                           new PointF(-s * .05f, s * .32f), new PointF(-s * .06f, s * .12f), new PointF(-s * .44f, s * .22f), new PointF(-s * .44f, s * .14f), new PointF(-s * .06f, -s * .06f), new PointF(-s * .06f, -s * .3f) };
        using (var b = new SolidBrush(AmPal.A(c, 60))) g.FillPolygon(b, body); using (var pen = P(c, w * .8f)) g.DrawPolygon(pen, body);
        break; }
      case "crosshair": case "target": {
        float R = s * .4f; float cx = x + s / 2, cy = y + s / 2;
        using (var pen = P(c, w)) { g.DrawEllipse(pen, cx - R, cy - R, 2 * R, 2 * R); g.DrawEllipse(pen, cx - R * .45f, cy - R * .45f, R * .9f, R * .9f);
          g.DrawLine(pen, cx, cy - s * .48f, cx, cy - R * .6f); g.DrawLine(pen, cx, cy + R * .6f, cx, cy + s * .48f); g.DrawLine(pen, cx - s * .48f, cy, cx - R * .6f, cy); g.DrawLine(pen, cx + R * .6f, cy, cx + s * .48f, cy); }
        using (var b = new SolidBrush(AmPal.Red)) g.FillEllipse(b, cx - s * .04f, cy - s * .04f, s * .08f, s * .08f);
        break; }
      case "cabinet": case "arcade": {
        // upright cabinet side-on-front: marquee, screen, control panel, base
        var outline = new[] { new PointF(.24f, .04f), new PointF(.76f, .04f), new PointF(.76f, .56f), new PointF(.84f, .66f), new PointF(.84f, .72f), new PointF(.76f, .74f), new PointF(.76f, .96f), new PointF(.24f, .96f), new PointF(.24f, .74f), new PointF(.16f, .72f), new PointF(.16f, .66f), new PointF(.24f, .56f) };
        var op = new PointF[outline.Length]; for (int i = 0; i < op.Length; i++) op[i] = new PointF(x + s * outline[i].X, y + s * outline[i].Y);
        using (var b = new SolidBrush(AmPal.A(c, 40))) g.FillPolygon(b, op); using (var pen = P(c, w)) g.DrawPolygon(pen, op);
        using (var b = new SolidBrush(AmPal.A(AmPal.Magenta, 200))) g.FillRectangle(b, x + s * .3f, y + s * .09f, s * .4f, s * .08f);
        using (var p = Round(new RectangleF(x + s * .3f, y + s * .22f, s * .4f, s * .3f), s * .03f)) { using (var b = new SolidBrush(AmPal.Card)) g.FillPath(b, p); using (var pen = P(c, w * .7f)) g.DrawPath(pen, p); }
        using (var b = new SolidBrush(c)) { g.FillEllipse(b, x + s * .33f, y + s * .62f, s * .07f, s * .07f); g.FillEllipse(b, x + s * .52f, y + s * .63f, s * .06f, s * .06f); g.FillEllipse(b, x + s * .61f, y + s * .63f, s * .06f, s * .06f); }
        break; }
      case "buttons": case "panel": {
        using (var p = Round(new RectangleF(x + s * .04f, y + s * .5f, s * .92f, s * .34f), s * .06f)) { using (var b = new SolidBrush(AmPal.A(c, 40))) g.FillPath(b, p); using (var pen = P(c, w)) g.DrawPath(pen, p); }
        using (var pen = P(c, s / 14)) g.DrawLine(pen, x + s * .2f, y + s * .62f, x + s * .2f, y + s * .3f);
        using (var b = new SolidBrush(AmPal.Magenta)) g.FillEllipse(b, x + s * .1f, y + s * .18f, s * .2f, s * .2f);
        var cols = new[] { AmPal.Red, AmPal.Amber, AmPal.Green, AmPal.Cyan, AmPal.Violet, Color.White };
        for (int i = 0; i < 6; i++) using (var b = new SolidBrush(cols[i])) g.FillEllipse(b, x + s * (.4f + (i % 3) * .17f), y + s * (.56f + (i / 3) * .13f), s * .1f, s * .1f);
        break; }
      default: {
        using (var pen = P(c, w)) g.DrawEllipse(pen, x + s * .15f, y + s * .15f, s * .7f, s * .7f);
        break; }
    }
    g.Restore(st);
  }
  public static string IconForRole(string role) {
    switch ((role ?? "").ToLowerInvariant()) {
      case "wheel": return "wheel"; case "pedals": return "pedals"; case "handbrake": return "handbrake"; case "shifter": return "shifter";
      case "gamepad": case "pad": case "xinput": return "gamepad"; case "lightgun": case "gun": return "gun"; case "trackball": case "spinner": return "trackball";
      case "flight": case "flightstick": case "joystick": case "stick": case "arcade": return "joystick"; case "keyboard": return "keyboard"; case "mouse": return "mouse";
      case "touch": return "touch"; case "display": return "display"; case "wiimote": return "wiimote"; case "gcadapter": return "gamepad"; default: return "joystick";
    }
  }
}

// live joystick state through winmm (works without focus, any device the OS sees)
public static class AmJoyLive {
  [StructLayout(LayoutKind.Sequential)] public struct JOYINFOEX { public int dwSize, dwFlags, dwXpos, dwYpos, dwZpos, dwRpos, dwUpos, dwVpos, dwButtons, dwButtonNumber, dwPOV, dwReserved1, dwReserved2; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct JOYCAPS {
    public ushort wMid, wPid; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
    public int wXmin, wXmax, wYmin, wYmax, wZmin, wZmax, wNumButtons, wPeriodMin, wPeriodMax, wRmin, wRmax, wUmin, wUmax, wVmin, wVmax, wCaps, wMaxAxes, wNumAxes, wMaxButtons;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szRegKey; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szOEMVxD; }
  [DllImport("winmm.dll")] static extern int joyGetPosEx(int id, ref JOYINFOEX info);
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int joyGetDevCapsW(IntPtr id, ref JOYCAPS caps, int size);
  public class Dev { public int Id; public string Name; public int Axes; public int Buttons; public bool HasPov; public float[] Axis = new float[6]; public uint ButtonBits; public int Pov = -1; public bool Ok; }
  public static Dev[] List() {
    var l = new System.Collections.Generic.List<Dev>();
    for (int i = 0; i < 16; i++) {
      var c = new JOYCAPS(); if (joyGetDevCapsW((IntPtr)i, ref c, Marshal.SizeOf(c)) != 0) continue;
      var d = new Dev { Id = i, Name = c.szPname, Axes = c.wNumAxes, Buttons = c.wNumButtons, HasPov = (c.wCaps & 0x10) != 0 }; if (Read(d)) l.Add(d);
    }
    return l.ToArray();
  }
  // axes normalised to -1..1
  public static bool Read(Dev d) {
    var j = new JOYINFOEX(); j.dwSize = Marshal.SizeOf(j); j.dwFlags = 0xFF;
    bool ok = joyGetPosEx(d.Id, ref j) == 0; if (!ok) return d.Ok;   // keep the last good state on a failed read (no phantom release/press)
    d.Ok = true;
    int[] v = { j.dwXpos, j.dwYpos, j.dwZpos, j.dwRpos, j.dwUpos, j.dwVpos };
    for (int k = 0; k < 6; k++) d.Axis[k] = (v[k] - 32767.5f) / 32767.5f;
    d.ButtonBits = (uint)j.dwButtons; d.Pov = (d.HasPov && j.dwPOV != 0xFFFF && j.dwPOV <= 35900) ? j.dwPOV : -1; return true;   // devices without a hat report 0 = "up"
  }
  // cached device list (re-enumerated every 3 s); a failed read keeps that device's previous buttons
  static Dev[] cache; static DateTime cacheAt = DateTime.MinValue;
  public static long AnyButtons() {
    if (cache == null || (DateTime.Now - cacheAt).TotalSeconds > 3) { var fresh = List(); if (cache != null) foreach (var f in fresh) foreach (var o in cache) if (o.Id == f.Id && !f.Ok) f.ButtonBits = o.ButtonBits; cache = fresh; cacheAt = DateTime.Now; }
    else foreach (var d in cache) Read(d);
    long all = 0; foreach (var d in cache) all |= d.ButtonBits; return all;
  }
}
'@
. (Join-Path $PSScriptRoot 'AmTypeCache.ps1'); Add-AmCachedType -Source $amVisualSrc -References System.Drawing -ProbeType AmDraw   # compiled once, cached DLL after
}
