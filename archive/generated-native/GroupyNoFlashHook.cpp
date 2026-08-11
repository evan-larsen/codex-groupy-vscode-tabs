// Experimental, version-specific helper for Groupy 2.3.1.
// A WH_CBT hook runs in Groupy's UI thread, before its Rename Tab dialog activates.
// The installed build tools do not include the Windows SDK headers. The small declaration set
// below is the x64 Win32 ABI used by this helper; user32 entry points are loaded at runtime.
using BOOL = int;
using BYTE = unsigned char;
using DWORD = unsigned long;
using UINT = unsigned int;
using LONG_PTR = __int64;
using INT_PTR = __int64;
using WPARAM = unsigned __int64;
using LPARAM = __int64;
using LRESULT = __int64;
using HWND = void*;
using HHOOK = void*;
using HMODULE = void*;
using HANDLE = void*;
using FARPROC = int(__stdcall*)();
using LPCWSTR = const wchar_t*;
using LPVOID = void*;

#define WINAPI __stdcall
#define CALLBACK __stdcall
#define APIENTRY WINAPI
#define TRUE 1
#define FALSE 0
#define WH_CBT 5
#define HCBT_CREATEWND 3
#define HCBT_ACTIVATE 5
#define GWL_EXSTYLE -20
#define WS_EX_LAYERED 0x00080000L
#define WS_EX_NOACTIVATE 0x08000000L
#define LWA_ALPHA 0x00000002
#define SW_HIDE 0
#define FILE_APPEND_DATA 0x0004
#define FILE_SHARE_READ 0x0001
#define FILE_SHARE_WRITE 0x0002
#define OPEN_ALWAYS 4
#define FILE_ATTRIBUTE_NORMAL 0x00000080
#define INVALID_HANDLE_VALUE ((HANDLE)(INT_PTR)-1)
#define GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS 0x00000004
#define GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT 0x00000002

extern "C" __declspec(dllimport) HMODULE WINAPI LoadLibraryW(LPCWSTR);
extern "C" __declspec(dllimport) FARPROC WINAPI GetProcAddress(HMODULE, const char*);
extern "C" __declspec(dllimport) BOOL WINAPI GetModuleHandleExW(DWORD, LPCWSTR, HMODULE*);
extern "C" __declspec(dllimport) DWORD WINAPI GetLastError();
extern "C" __declspec(dllimport) HANDLE WINAPI CreateFileW(LPCWSTR, DWORD, DWORD, LPVOID, DWORD, DWORD, HANDLE);
extern "C" __declspec(dllimport) BOOL WINAPI WriteFile(HANDLE, const void*, DWORD, DWORD*, LPVOID);
extern "C" __declspec(dllimport) BOOL WINAPI CloseHandle(HANDLE);

using HOOKPROC = LRESULT(CALLBACK*)(int, WPARAM, LPARAM);
using SetWindowsHookExWFn = HHOOK(WINAPI*)(int, HOOKPROC, HMODULE, DWORD);
using UnhookWindowsHookExFn = BOOL(WINAPI*)(HHOOK);
using CallNextHookExFn = LRESULT(WINAPI*)(HHOOK, int, WPARAM, LPARAM);
using GetClassNameWFn = int(WINAPI*)(HWND, wchar_t*, int);
using GetWindowLongPtrWFn = LONG_PTR(WINAPI*)(HWND, int);
using SetWindowLongPtrWFn = LONG_PTR(WINAPI*)(HWND, int, LONG_PTR);
using SetLayeredWindowAttributesFn = BOOL(WINAPI*)(HWND, DWORD, BYTE, DWORD);
using ShowWindowFn = BOOL(WINAPI*)(HWND, int);

struct User32 {
    SetWindowsHookExWFn setWindowsHookExW;
    UnhookWindowsHookExFn unhookWindowsHookEx;
    CallNextHookExFn callNextHookEx;
    GetClassNameWFn getClassNameW;
    GetWindowLongPtrWFn getWindowLongPtrW;
    SetWindowLongPtrWFn setWindowLongPtrW;
    SetLayeredWindowAttributesFn setLayeredWindowAttributes;
    ShowWindowFn showWindow;
};

static User32* GetUser32() {
    static User32 api = {};
    if (api.setWindowsHookExW) return &api;
    HMODULE user32 = LoadLibraryW(L"user32.dll");
    if (!user32) return nullptr;
    api.setWindowsHookExW = (SetWindowsHookExWFn)GetProcAddress(user32, "SetWindowsHookExW");
    api.unhookWindowsHookEx = (UnhookWindowsHookExFn)GetProcAddress(user32, "UnhookWindowsHookEx");
    api.callNextHookEx = (CallNextHookExFn)GetProcAddress(user32, "CallNextHookEx");
    api.getClassNameW = (GetClassNameWFn)GetProcAddress(user32, "GetClassNameW");
    api.getWindowLongPtrW = (GetWindowLongPtrWFn)GetProcAddress(user32, "GetWindowLongPtrW");
    api.setWindowLongPtrW = (SetWindowLongPtrWFn)GetProcAddress(user32, "SetWindowLongPtrW");
    api.setLayeredWindowAttributes = (SetLayeredWindowAttributesFn)GetProcAddress(user32, "SetLayeredWindowAttributes");
    api.showWindow = (ShowWindowFn)GetProcAddress(user32, "ShowWindow");
    return api.setWindowsHookExW && api.unhookWindowsHookEx && api.callNextHookEx &&
           api.getClassNameW && api.getWindowLongPtrW && api.setWindowLongPtrW &&
           api.setLayeredWindowAttributes && api.showWindow ? &api : nullptr;
}

static HHOOK g_hooks[128] = {};
static unsigned int g_hookCount = 0;

static void LogCbtEvent(int code) {
    static const wchar_t logPath[] = L"C:\\Users\\evanl\\Documents\\groupy-vscode-codex-tabs\\work\\GroupyNoFlashHook.log";
    const char* message = code == HCBT_CREATEWND ? "CBT create #32770\r\n" : "CBT activate #32770\r\n";
    DWORD length = code == HCBT_CREATEWND ? 20 : 22;
    HANDLE file = CreateFileW(logPath, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, message, length, &written, nullptr);
    CloseHandle(file);
}

static bool IsDialog(HWND hwnd) {
    wchar_t className[32] = {};
    User32* api = GetUser32();
    if (!api || api->getClassNameW(hwnd, className, 32) <= 0) return false;
    const wchar_t expected[] = L"#32770";
    for (int i = 0; expected[i] || className[i]; ++i) if (expected[i] != className[i]) return false;
    return true;
}

static void MakeInvisible(HWND hwnd) {
    User32* api = GetUser32();
    if (!api) return;
    LONG_PTR exStyle = api->getWindowLongPtrW(hwnd, GWL_EXSTYLE);
    api->setWindowLongPtrW(hwnd, GWL_EXSTYLE, exStyle | WS_EX_LAYERED | WS_EX_NOACTIVATE);
    api->setLayeredWindowAttributes(hwnd, 0, 0, LWA_ALPHA);
}

extern "C" __declspec(dllexport) LRESULT CALLBACK GroupyCbtProc(int code, WPARAM wParam, LPARAM lParam) {
    if ((code == HCBT_CREATEWND || code == HCBT_ACTIVATE) && IsDialog((HWND)wParam)) {
        HWND dialog = (HWND)wParam;
        LogCbtEvent(code);
        MakeInvisible(dialog);
        if (code == HCBT_ACTIVATE) {
            // Groupy can still receive the native Edit/OK messages, but Windows does not give
            // the temporary dialog an activated, visible frame.
            User32* api = GetUser32();
            if (api) api->showWindow(dialog, SW_HIDE);
            return 1;
        }
    }
    User32* api = GetUser32();
    return api ? api->callNextHookEx(nullptr, code, wParam, lParam) : 0;
}

extern "C" __declspec(dllexport) BOOL WINAPI InstallNoFlashHook(DWORD threadId) {
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)&GroupyCbtProc, &module)) {
        return FALSE;
    }
    User32* api = GetUser32();
    if (!api) return FALSE;
    HHOOK hook = api->setWindowsHookExW(WH_CBT, GroupyCbtProc, module, threadId);
    if (!hook) return FALSE;
    if (g_hookCount >= 128) {
        api->unhookWindowsHookEx(hook);
        return FALSE;
    }
    g_hooks[g_hookCount++] = hook;
    return TRUE;
}

extern "C" __declspec(dllexport) void WINAPI RemoveNoFlashHooks() {
    User32* api = GetUser32();
    if (api) for (unsigned int i = 0; i < g_hookCount; ++i) api->unhookWindowsHookEx(g_hooks[i]);
    g_hookCount = 0;
}

extern "C" __declspec(dllexport) DWORD WINAPI GetNoFlashHookLastError() {
    return GetLastError();
}

BOOL APIENTRY DllMain(HMODULE, DWORD, LPVOID) { return TRUE; }
