// WheelMapInput.cs - dependency-free DirectInput8 / XInput / keyboard polling for WheelMap.ps1
// Compiled at runtime by PowerShell 5.1 (Add-Type, C# 5, .NET Framework). No downloads, no SharpDX.
//
// Data format: we register a custom DIDATAFORMAT that is byte-identical to the first 176 bytes of
// DIJOYSTATE2 (X,Y,Z,Rx,Ry,Rz, 2 sliders, 4 POVs, 128 buttons). This means the object offsets we
// report are exactly SharpDX's JoystickOffset values, which TeknoParrot stores in
// <DirectInputButton><Button>: X=0 Y=4 Z=8 RotationX=12 RotationY=16 RotationZ=20 Sliders0=24
// Sliders1=28 PointOfViewControllers0..3=32..44 Buttons0..127=48..175.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace WheelMap
{
    public class DIObjectInfo
    {
        public string Name;       // HID usage name reported by the driver, e.g. "Wheel axis", "Accelerator"
        public int Offset;        // offset inside our DIJOYSTATE2-compatible format (= SharpDX JoystickOffset)
        public string OffsetName; // SharpDX JoystickOffset name, e.g. "X", "RotationZ", "Sliders0", "Buttons4"
        public string Kind;       // Axis | Button | POV | Other
        public int Type;
        public int Flags;
        public int UsagePage;
        public int Usage;
        public override string ToString() { return string.Format("{0,-10} ofs={1,-3} {2} '{3}'", Kind, Offset, OffsetName, Name); }
    }

    public class DIDeviceInfo
    {
        public int EnumIndex;          // 1-based order in EnumDevices(GAMECTRL, ATTACHEDONLY) - what Supermodel/m2 call JOYn
        public Guid InstanceGuid;      // what TeknoParrot <JoystickGuid> / Cemu <uuid> use
        public Guid ProductGuid;
        public string InstanceName;
        public string ProductName;     // what Dolphin "DInput/0/<name>" and Cemu <display_name> use
        public int DevType;            // raw dwDevType
        public string TypeName;        // SharpDX DeviceType name (TeknoParrot BindNameDi prefix): Driving, Joystick, Gamepad, ...
        public int SubType;
        public string Vid;             // 4 hex digits, from ProductGuid "PIDVID" form
        public string Pid;
        public int UsagePage;
        public int Usage;
        public bool ForceFeedback;
        public int AxisCount, ButtonCount, PovCount;
        public bool IsXInputDevice;    // heuristic: "IG_" in device path is not available here; filled by PowerShell
        public List<DIObjectInfo> Objects = new List<DIObjectInfo>();
        public string Error;
        public override string ToString() { return string.Format("#{0} {1} [{2}] VID_{3}&PID_{4} {5}", EnumIndex, ProductName, TypeName, Vid, Pid, InstanceGuid); }
    }

    public class JoyState
    {
        public int[] Axes = new int[8];      // X,Y,Z,Rx,Ry,Rz,Slider0,Slider1 normalised to 0..65535
        public int[] Povs = new int[4];      // hundredths of degrees, -1 = centred
        public byte[] Buttons = new byte[128];
        public bool Ok;
        public int HResult;
    }

    public static class DI
    {
        public static readonly string[] AxisNames = { "X", "Y", "Z", "RotationX", "RotationY", "RotationZ", "Sliders0", "Sliders1" };

        public static string OffsetName(int ofs)
        {
            if (ofs >= 0 && ofs < 32 && ofs % 4 == 0) return AxisNames[ofs / 4];
            if (ofs >= 32 && ofs < 48 && ofs % 4 == 0) return "PointOfViewControllers" + ((ofs - 32) / 4);
            if (ofs >= 48 && ofs < 176) return "Buttons" + (ofs - 48);
            return "Offset" + ofs;
        }

        public static string TypeNameOf(int devType)
        {
            switch (devType & 0xFF)
            {
                case 0x11: return "Device";
                case 0x12: return "Mouse";
                case 0x13: return "Keyboard";
                case 0x14: return "Joystick";
                case 0x15: return "Gamepad";
                case 0x16: return "Driving";
                case 0x17: return "Flight";
                case 0x18: return "FirstPerson";
                case 0x19: return "ControlDevice";
                case 0x1A: return "ScreenPointer";
                case 0x1B: return "Remote";
                case 0x1C: return "Supplemental";
                default: return "Unknown" + (devType & 0xFF);
            }
        }

        // ---------------------------------------------------------------- native
        const int DIRECTINPUT_VERSION = 0x0800;
        const int DI8DEVCLASS_GAMECTRL = 4;
        const int DIEDFL_ATTACHEDONLY = 1;
        const int DIDFT_ALL = 0;
        const int DISCL_NONEXCLUSIVE = 2;
        const int DISCL_BACKGROUND = 8;
        internal const int DIERR_INPUTLOST = unchecked((int)0x8007001E);
        internal const int DIERR_NOTACQUIRED = unchecked((int)0x8007000C);

        static readonly Guid IID_IDirectInput8W = new Guid("BF798031-483A-4DA2-AA99-5D64ED369700");
        internal static readonly Guid GUID_XAxis = new Guid("A36D02E0-C9F3-11CF-BFC7-444553540000");
        internal static readonly Guid GUID_YAxis = new Guid("A36D02E1-C9F3-11CF-BFC7-444553540000");
        internal static readonly Guid GUID_ZAxis = new Guid("A36D02E2-C9F3-11CF-BFC7-444553540000");
        internal static readonly Guid GUID_RxAxis = new Guid("A36D02F4-C9F3-11CF-BFC7-444553540000");
        internal static readonly Guid GUID_RyAxis = new Guid("A36D02F5-C9F3-11CF-BFC7-444553540000");
        internal static readonly Guid GUID_RzAxis = new Guid("A36D02E3-C9F3-11CF-BFC7-444553540000");
        internal static readonly Guid GUID_Slider = new Guid("A36D02E4-C9F3-11CF-BFC7-444553540000");
        internal static readonly Guid GUID_POV = new Guid("A36D02F2-C9F3-11CF-BFC7-444553540000");
        public static readonly Guid GUID_SysKeyboard = new Guid("6F1D2B61-D5A0-11CF-BFC7-444553540000");

        [DllImport("dinput8.dll")]
        static extern int DirectInput8Create(IntPtr hinst, int dwVersion, [In] ref Guid riidltf, out IntPtr ppvOut, IntPtr punkOuter);
        [DllImport("kernel32.dll")]
        static extern IntPtr GetModuleHandle(string name);
        [DllImport("kernel32.dll")]
        internal static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr CreateWindowEx(int exStyle, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        internal delegate int EnumDevicesCallback(IntPtr lpddi, IntPtr pvRef);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        internal delegate int EnumObjectsCallback(IntPtr lpddoi, IntPtr pvRef);

        [ComImport, Guid("BF798031-483A-4DA2-AA99-5D64ED369700"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IDirectInput8W
        {
            [PreserveSig] int CreateDevice([In] ref Guid rguid, out IntPtr lplpDirectInputDevice, IntPtr pUnkOuter);
            [PreserveSig] int EnumDevices(int dwDevType, [MarshalAs(UnmanagedType.FunctionPtr)] EnumDevicesCallback lpCallback, IntPtr pvRef, int dwFlags);
            [PreserveSig] int GetDeviceStatus([In] ref Guid rguidInstance);
            [PreserveSig] int RunControlPanel(IntPtr hwndOwner, int dwFlags);
            [PreserveSig] int Initialize(IntPtr hinst, int dwVersion);
            [PreserveSig] int FindDevice(IntPtr a, IntPtr b, IntPtr c);
            [PreserveSig] int EnumDevicesBySemantics(IntPtr a, IntPtr b, IntPtr c, IntPtr d, int e);
            [PreserveSig] int ConfigureDevices(IntPtr a, IntPtr b, int c, IntPtr d);
        }

        [ComImport, Guid("54D41081-DC15-4833-A41B-748F73A38179"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IDirectInputDevice8W
        {
            [PreserveSig] int GetCapabilities(ref DIDEVCAPS caps);
            [PreserveSig] int EnumObjects([MarshalAs(UnmanagedType.FunctionPtr)] EnumObjectsCallback cb, IntPtr pvRef, int dwFlags);
            [PreserveSig] int GetProperty(IntPtr rguidProp, IntPtr pdiph);
            [PreserveSig] int SetProperty(IntPtr rguidProp, IntPtr pdiph);
            [PreserveSig] int Acquire();
            [PreserveSig] int Unacquire();
            [PreserveSig] int GetDeviceState(int cbData, IntPtr lpvData);
            [PreserveSig] int GetDeviceData(int a, IntPtr b, IntPtr c, int d);
            [PreserveSig] int SetDataFormat(IntPtr lpdf);
            [PreserveSig] int SetEventNotification(IntPtr h);
            [PreserveSig] int SetCooperativeLevel(IntPtr hwnd, int dwFlags);
            [PreserveSig] int GetObjectInfo(IntPtr a, int b, int c);
            [PreserveSig] int GetDeviceInfo(IntPtr pdidi);
            [PreserveSig] int RunControlPanel(IntPtr hwnd, int flags);
            [PreserveSig] int Initialize(IntPtr hinst, int ver, [In] ref Guid g);
            [PreserveSig] int CreateEffect(IntPtr a, IntPtr b, IntPtr c, IntPtr d);
            [PreserveSig] int EnumEffects(IntPtr a, IntPtr b, int c);
            [PreserveSig] int GetEffectInfo(IntPtr a, IntPtr b);
            [PreserveSig] int GetForceFeedbackState(out int state);
            [PreserveSig] int SendForceFeedbackCommand(int flags);
            [PreserveSig] int EnumCreatedEffectObjects(IntPtr a, IntPtr b, int c);
            [PreserveSig] int Escape(IntPtr a);
            [PreserveSig] int Poll();
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct DIDEVCAPS
        {
            public int dwSize, dwFlags, dwDevType, dwAxes, dwButtons, dwPOVs, dwFFSamplePeriod, dwFFMinTimeResolution, dwFirmwareRevision, dwHardwareRevision, dwFFDriverVersion;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct DIDEVICEINSTANCEW
        {
            public int dwSize;
            public Guid guidInstance;
            public Guid guidProduct;
            public int dwDevType;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string tszInstanceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string tszProductName;
            public Guid guidFFDriver;
            public ushort wUsagePage;
            public ushort wUsage;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct DIDEVICEOBJECTINSTANCEW
        {
            public int dwSize;
            public Guid guidType;
            public int dwOfs;
            public int dwType;
            public int dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string tszName;
            public int dwFFMaxForce;
            public int dwFFForceResolution;
            public ushort wCollectionNumber, wDesignatorIndex, wUsagePage, wUsage;
            public int dwDimension;
            public ushort wExponent, wReserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct DIOBJECTDATAFORMAT { public IntPtr pguid; public int dwOfs; public int dwType; public int dwFlags; }

        [StructLayout(LayoutKind.Sequential)]
        struct DIDATAFORMAT { public int dwSize; public int dwObjSize; public int dwFlags; public int dwDataSize; public int dwNumObjs; public IntPtr rgodf; }

        [StructLayout(LayoutKind.Sequential)]
        internal struct DIPROPRANGE { public int dwSize, dwHeaderSize, dwObj, dwHow, lMin, lMax; }

        public const int StateSize = 176;
        static IntPtr s_dataFormat = IntPtr.Zero;
        static IDirectInput8W s_di;
        static IntPtr s_hwnd = IntPtr.Zero;

        static IntPtr AllocGuid(Guid g)
        {
            IntPtr p = Marshal.AllocHGlobal(16);
            Marshal.Copy(g.ToByteArray(), 0, p, 16);
            return p;
        }

        internal static IntPtr DataFormat()
        {
            if (s_dataFormat != IntPtr.Zero) return s_dataFormat;
            var objs = new List<DIOBJECTDATAFORMAT>();
            const int OPT = unchecked((int)0x80000000), ANY = 0x00FFFF00, AXIS = 3, POV = 0x10, BTN = 0x0C, ASPECTPOS = 0x100;
            Guid[] axisGuids = { GUID_XAxis, GUID_YAxis, GUID_ZAxis, GUID_RxAxis, GUID_RyAxis, GUID_RzAxis, GUID_Slider, GUID_Slider };
            for (int i = 0; i < 8; i++) objs.Add(new DIOBJECTDATAFORMAT { pguid = AllocGuid(axisGuids[i]), dwOfs = i * 4, dwType = OPT | ANY | AXIS, dwFlags = ASPECTPOS });
            IntPtr pov = AllocGuid(GUID_POV);
            for (int i = 0; i < 4; i++) objs.Add(new DIOBJECTDATAFORMAT { pguid = pov, dwOfs = 32 + i * 4, dwType = OPT | ANY | POV, dwFlags = 0 });
            for (int i = 0; i < 128; i++) objs.Add(new DIOBJECTDATAFORMAT { pguid = IntPtr.Zero, dwOfs = 48 + i, dwType = OPT | ANY | BTN, dwFlags = 0 });
            int objSize = Marshal.SizeOf(typeof(DIOBJECTDATAFORMAT));
            IntPtr arr = Marshal.AllocHGlobal(objSize * objs.Count);
            for (int i = 0; i < objs.Count; i++) Marshal.StructureToPtr(objs[i], new IntPtr(arr.ToInt64() + i * objSize), false);
            var df = new DIDATAFORMAT { dwSize = Marshal.SizeOf(typeof(DIDATAFORMAT)), dwObjSize = objSize, dwFlags = 1 /*DIDF_ABSAXIS*/, dwDataSize = StateSize, dwNumObjs = objs.Count, rgodf = arr };
            s_dataFormat = Marshal.AllocHGlobal(df.dwSize);
            Marshal.StructureToPtr(df, s_dataFormat, false);
            return s_dataFormat;
        }

        internal static IDirectInput8W Instance()
        {
            if (s_di != null) return s_di;
            Guid iid = IID_IDirectInput8W;
            IntPtr p;
            int hr = DirectInput8Create(GetModuleHandle(null), DIRECTINPUT_VERSION, ref iid, out p, IntPtr.Zero);
            if (hr < 0) throw new Exception("DirectInput8Create failed 0x" + hr.ToString("X8"));
            s_di = (IDirectInput8W)Marshal.GetObjectForIUnknown(p);
            Marshal.Release(p);
            return s_di;
        }

        internal static IntPtr Hwnd()
        {
            if (s_hwnd != IntPtr.Zero) return s_hwnd;
            s_hwnd = GetConsoleWindow();
            return s_hwnd;
        }

        internal static IntPtr FallbackHwnd()
        {
            // hidden top-level STATIC window owned by this process
            return CreateWindowEx(0, "STATIC", "WheelMapDI", 0, 0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
        }

        /// <summary>Enumerate attached game controllers (same flags Supermodel/m2/TeknoParrot use).</summary>
        public static List<DIDeviceInfo> Enumerate(bool withObjects)
        {
            var list = new List<DIDeviceInfo>();
            var di = Instance();
            EnumDevicesCallback cb = (lpddi, pv) =>
            {
                var d = (DIDEVICEINSTANCEW)Marshal.PtrToStructure(lpddi, typeof(DIDEVICEINSTANCEW));
                var info = new DIDeviceInfo();
                info.EnumIndex = list.Count + 1;
                info.InstanceGuid = d.guidInstance;
                info.ProductGuid = d.guidProduct;
                info.InstanceName = d.tszInstanceName;
                info.ProductName = d.tszProductName;
                info.DevType = d.dwDevType;
                info.TypeName = TypeNameOf(d.dwDevType);
                info.SubType = (d.dwDevType >> 8) & 0xFF;
                info.UsagePage = d.wUsagePage;
                info.Usage = d.wUsage;
                byte[] pg = d.guidProduct.ToByteArray();
                // "PIDVID" product GUID: Data1 = PID<<16 | VID, Data4 = 'P','I','D','V','I','D'
                if (Encoding.ASCII.GetString(pg, 10, 6) == "PIDVID")
                {
                    uint d1 = BitConverter.ToUInt32(pg, 0);
                    info.Vid = (d1 & 0xFFFF).ToString("X4");
                    info.Pid = (d1 >> 16).ToString("X4");
                }
                list.Add(info);
                return 1; // DIENUM_CONTINUE
            };
            int hr = di.EnumDevices(DI8DEVCLASS_GAMECTRL, cb, IntPtr.Zero, DIEDFL_ATTACHEDONLY);
            GC.KeepAlive(cb);
            if (hr < 0) throw new Exception("EnumDevices failed 0x" + hr.ToString("X8"));
            if (withObjects)
            {
                foreach (var info in list)
                {
                    try
                    {
                        using (var dev = new DIDevice(info.InstanceGuid))
                        {
                            info.ForceFeedback = dev.ForceFeedback;
                            info.AxisCount = dev.Caps.dwAxes;
                            info.ButtonCount = dev.Caps.dwButtons;
                            info.PovCount = dev.Caps.dwPOVs;
                            info.Objects = dev.Objects();
                        }
                    }
                    catch (Exception ex) { info.Error = ex.Message; }
                }
            }
            return list;
        }
    }

    public class DIDevice : IDisposable
    {
        DI.IDirectInputDevice8W _dev;
        IntPtr _buf = Marshal.AllocHGlobal(DI.StateSize);
        public Guid InstanceGuid;
        internal DI.DIDEVCAPS Caps;
        public bool ForceFeedback { get { return (Caps.dwFlags & 0x100) != 0; } }
        public string CoopInfo;
        public bool Acquired;

        public DIDevice(Guid instance)
        {
            InstanceGuid = instance;
            var di = DI.Instance();
            IntPtr p;
            int hr = di.CreateDevice(ref instance, out p, IntPtr.Zero);
            if (hr < 0) throw new Exception("CreateDevice failed 0x" + hr.ToString("X8"));
            _dev = (DI.IDirectInputDevice8W)Marshal.GetObjectForIUnknown(p);
            Marshal.Release(p);
            hr = _dev.SetDataFormat(DI.DataFormat());
            if (hr < 0) throw new Exception("SetDataFormat failed 0x" + hr.ToString("X8"));
            const int flags = 2 | 8; // NONEXCLUSIVE | BACKGROUND
            hr = _dev.SetCooperativeLevel(DI.Hwnd(), flags);
            if (hr < 0)
            {
                hr = _dev.SetCooperativeLevel(DI.FallbackHwnd(), flags);
                CoopInfo = hr < 0 ? "default (SetCooperativeLevel failed 0x" + hr.ToString("X8") + ")" : "hidden window";
            }
            else CoopInfo = "console window";
            Caps = new DI.DIDEVCAPS { dwSize = Marshal.SizeOf(typeof(DI.DIDEVCAPS)) };
            _dev.GetCapabilities(ref Caps);
            NormaliseRanges();
        }

        void NormaliseRanges()
        {
            // DIPROP_RANGE = MAKEDIPROP(4); per-instance, does not change any global calibration.
            var r = new DI.DIPROPRANGE { dwSize = 24, dwHeaderSize = 16, dwHow = 1 /*DIPH_BYOFFSET*/, lMin = 0, lMax = 65535 };
            IntPtr p = Marshal.AllocHGlobal(24);
            try
            {
                for (int i = 0; i < 8; i++)
                {
                    r.dwObj = i * 4;
                    Marshal.StructureToPtr(r, p, false);
                    _dev.SetProperty(new IntPtr(4), p); // absent axes just fail with DIERR_OBJECTNOTFOUND
                }
            }
            finally { Marshal.FreeHGlobal(p); }
        }

        public List<DIObjectInfo> Objects()
        {
            // EnumObjects reports *native* offsets; translate to our DIJOYSTATE2-compatible slots the same
            // way DirectInput assigns DIDFT_ANYINSTANCE entries: by guidType, in enumeration order.
            var list = new List<DIObjectInfo>();
            int sliders = 0, povs = 0, buttons = 0;
            DI.EnumObjectsCallback cb = (lpddoi, pv) =>
            {
                var o = (DI.DIDEVICEOBJECTINSTANCEW)Marshal.PtrToStructure(lpddoi, typeof(DI.DIDEVICEOBJECTINSTANCEW));
                var oi = new DIObjectInfo { Name = o.tszName, Offset = -1, Type = o.dwType, Flags = o.dwFlags, UsagePage = o.wUsagePage, Usage = o.wUsage };
                Guid g = o.guidType;
                if ((o.dwType & 3) != 0)
                {
                    oi.Kind = "Axis";
                    if (g == DI.GUID_XAxis) oi.Offset = 0;
                    else if (g == DI.GUID_YAxis) oi.Offset = 4;
                    else if (g == DI.GUID_ZAxis) oi.Offset = 8;
                    else if (g == DI.GUID_RxAxis) oi.Offset = 12;
                    else if (g == DI.GUID_RyAxis) oi.Offset = 16;
                    else if (g == DI.GUID_RzAxis) oi.Offset = 20;
                    else if (g == DI.GUID_Slider && sliders < 2) oi.Offset = 24 + 4 * sliders++;
                }
                else if ((o.dwType & 0x0C) != 0) { oi.Kind = "Button"; if (buttons < 128) oi.Offset = 48 + buttons++; }
                else if ((o.dwType & 0x10) != 0) { oi.Kind = "POV"; if (povs < 4) oi.Offset = 32 + 4 * povs++; }
                else oi.Kind = "Other";
                oi.OffsetName = oi.Offset >= 0 ? DI.OffsetName(oi.Offset) : "";
                if (oi.Kind != "Other") list.Add(oi);
                return 1;
            };
            _dev.EnumObjects(cb, IntPtr.Zero, 0 /*DIDFT_ALL*/);
            GC.KeepAlive(cb);
            return list;
        }

        public JoyState Read()
        {
            var s = new JoyState();
            int hr = _dev.Poll();
            if (hr < 0 || !Acquired)
            {
                Acquired = _dev.Acquire() >= 0;
                _dev.Poll();
            }
            hr = _dev.GetDeviceState(DI.StateSize, _buf);
            if (hr == DI.DIERR_INPUTLOST || hr == DI.DIERR_NOTACQUIRED)
            {
                Acquired = _dev.Acquire() >= 0;
                hr = _dev.GetDeviceState(DI.StateSize, _buf);
            }
            s.HResult = hr;
            if (hr < 0) return s;
            s.Ok = true;
            for (int i = 0; i < 8; i++) s.Axes[i] = Marshal.ReadInt32(_buf, i * 4);
            for (int i = 0; i < 4; i++)
            {
                int v = Marshal.ReadInt32(_buf, 32 + i * 4);
                s.Povs[i] = (v & 0xFFFF) == 0xFFFF ? -1 : v;
            }
            Marshal.Copy(new IntPtr(_buf.ToInt64() + 48), s.Buttons, 0, 128);
            return s;
        }

        public void Dispose()
        {
            if (_dev != null)
            {
                try { _dev.Unacquire(); } catch { }
                Marshal.ReleaseComObject(_dev);
                _dev = null;
            }
            if (_buf != IntPtr.Zero) { Marshal.FreeHGlobal(_buf); _buf = IntPtr.Zero; }
        }
    }

    public class XIState
    {
        public int Index; public bool Connected; public int Buttons; public int LT, RT, LX, LY, RX, RY;
    }

    public static class XI
    {
        [StructLayout(LayoutKind.Sequential)]
        struct XINPUT_STATE { public uint dwPacketNumber; public ushort wButtons; public byte bLeftTrigger, bRightTrigger; public short sThumbLX, sThumbLY, sThumbRX, sThumbRY; }
        [DllImport("xinput1_4.dll", EntryPoint = "XInputGetState")] static extern int GetState14(int idx, out XINPUT_STATE s);
        [DllImport("xinput9_1_0.dll", EntryPoint = "XInputGetState")] static extern int GetState910(int idx, out XINPUT_STATE s);

        public static XIState Read(int idx)
        {
            XINPUT_STATE s;
            int r;
            try { r = GetState14(idx, out s); }
            catch (DllNotFoundException) { r = GetState910(idx, out s); }
            var o = new XIState { Index = idx, Connected = r == 0 };
            if (r == 0) { o.Buttons = s.wButtons; o.LT = s.bLeftTrigger; o.RT = s.bRightTrigger; o.LX = s.sThumbLX; o.LY = s.sThumbLY; o.RX = s.sThumbRX; o.RY = s.sThumbRY; }
            return o;
        }
    }

    /// <summary>RawInput device list - mouse-mode light guns (Sinden, AimTrak, Gun4IR) show up here as mice.</summary>
    public static class RawInput
    {
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICELIST { public IntPtr hDevice; public int dwType; }
        [DllImport("user32.dll", SetLastError = true)] static extern int GetRawInputDeviceList([Out] RAWINPUTDEVICELIST[] list, ref int count, int size);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern int GetRawInputDeviceInfo(IntPtr h, int cmd, StringBuilder data, ref int size);

        /// <summary>Returns "type|devicePath" strings; type is mouse, keyboard or hid.</summary>
        public static List<string> Devices()
        {
            var r = new List<string>();
            int n = 0, sz = Marshal.SizeOf(typeof(RAWINPUTDEVICELIST));
            GetRawInputDeviceList(null, ref n, sz);
            if (n <= 0) return r;
            var arr = new RAWINPUTDEVICELIST[n];
            if (GetRawInputDeviceList(arr, ref n, sz) < 0) return r;
            for (int i = 0; i < n; i++)
            {
                int len = 0;
                GetRawInputDeviceInfo(arr[i].hDevice, 0x20000007, null, ref len);
                var sb = new StringBuilder(len + 1);
                GetRawInputDeviceInfo(arr[i].hDevice, 0x20000007, sb, ref len);
                string t = arr[i].dwType == 0 ? "mouse" : arr[i].dwType == 1 ? "keyboard" : "hid";
                r.Add(t + "|" + sb.ToString());
            }
            return r;
        }
    }

    /// <summary>Keyboard / mouse-button polling via GetAsyncKeyState (works while console is unfocused).
    /// Used for keyboard encoders (I-PAC, Sinden/AimTrak/Gun4IR button-to-key modes) and mouse buttons.</summary>
    public static class Keys
    {
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
        public static List<int> Down()
        {
            var l = new List<int>();
            for (int vk = 1; vk < 255; vk++)
            {
                if (vk == 0x10 || vk == 0x11 || vk == 0x12) continue; // generic shift/ctrl/alt (L/R variants are reported)
                if ((GetAsyncKeyState(vk) & 0x8000) != 0) l.Add(vk);
            }
            return l;
        }
    }
}
