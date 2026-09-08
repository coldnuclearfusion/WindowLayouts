using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WindowLayouts;

public static class Displays
{
    /// <summary>지금 연결된 모니터 구성. 좌표는 가상 화면(주 모니터 왼쪽 위가 (0,0)) 물리 픽셀.</summary>
    public static DisplayConfig Current()
    {
        var list = new List<DisplayInfo>();
        Native.MonitorEnumProc callback = (IntPtr hMonitor, IntPtr hdc, ref Native.RECT rect, IntPtr data) =>
        {
            var info = new Native.MONITORINFOEX { cbSize = Marshal.SizeOf<Native.MONITORINFOEX>() };
            if (!Native.GetMonitorInfoW(hMonitor, ref info)) return true;

            string device = info.szDevice ?? "";
            string id = device;
            string name = device;
            var dd = new Native.DISPLAY_DEVICE { cb = Marshal.SizeOf<Native.DISPLAY_DEVICE>() };
            // 어댑터 이름(\\.\DISPLAY1)으로 그 출력에 붙은 모니터를 조회하면 재부팅 후에도 유지되는 장치 경로를 얻는다
            if (Native.EnumDisplayDevicesW(device, 0, ref dd, Native.EDD_GET_DEVICE_INTERFACE_NAME))
            {
                if (!string.IsNullOrEmpty(dd.DeviceID)) id = dd.DeviceID;
                if (!string.IsNullOrEmpty(dd.DeviceString)) name = dd.DeviceString;
            }
            var m = info.rcMonitor;
            list.Add(new DisplayInfo
            {
                Id = id,
                Name = name,
                X = m.Left,
                Y = m.Top,
                Width = m.Right - m.Left,
                Height = m.Bottom - m.Top,
                IsMain = (info.dwFlags & Native.MONITORINFOF_PRIMARY) != 0,
            });
            return true;
        };
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return new DisplayConfig { Displays = list };
    }
}
