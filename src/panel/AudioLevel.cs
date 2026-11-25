// AmPanel - the system's sound level, for audio-reactive lights (LEDBlinky's audio.lwax, done natively).
//
// Windows Core Audio: the default playback device's IAudioMeterInformation.GetPeakValue (0..1, what the volume mixer's
// green bar shows). One COM call per frame: no capture, no audio data copied, nothing installed.
// C# 5.
using System;
using System.Runtime.InteropServices;

static class AudioLevel
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int NotImpl1();                                                     // EnumAudioEndpoints
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation
    {
        [PreserveSig] int GetPeakValue(out float peak);
    }

    static IAudioMeterInformation meter;
    public static string LastError;

    // must be called on the thread that reads (an MTA background thread is fine)
    static int users;   // the attract animation and audio-follow rules share one meter

    public static bool Open()
    {
        lock (typeof(AudioLevel)) { if (meter != null) { users++; return true; } }
        try
        {
            var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            IMMDevice dev;
            if (en.GetDefaultAudioEndpoint(0 /* eRender */, 1 /* eMultimedia */, out dev) != 0 || dev == null) { LastError = "no playback device"; return false; }
            var iid = typeof(IAudioMeterInformation).GUID; object o;
            if (dev.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out o) != 0) { LastError = "no peak meter"; return false; }
            lock (typeof(AudioLevel)) { meter = (IAudioMeterInformation)o; users++; }
            return true;
        }
        catch (Exception e) { LastError = e.Message; meter = null; return false; }
    }

    public static float Peak()
    {
        float p = 0;
        try { if (meter != null) meter.GetPeakValue(out p); } catch { }
        return p;
    }

    public static void Close()
    {
        lock (typeof(AudioLevel))
        {
            if (--users > 0) return;
            users = 0;
            if (meter != null) { try { Marshal.ReleaseComObject(meter); } catch { } meter = null; }
        }
    }
}
