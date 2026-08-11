// Read-only diagnostic for Groupy tab-strip input. It is loaded into GroupyCtrl only through a
// thread-local WH_CALLWNDPROC hook and records the window messages Groupy receives while a user
// manually drags a tab to another group. It never changes, consumes, or synthesizes a message.
#include <windows.h>
#include <windowsx.h>
#include <stdio.h>

static HHOOK g_callHook = nullptr;
static HHOOK g_getMessageHook = nullptr;
static const wchar_t* kLog = L"C:\\Users\\evanl\\Documents\\groupy-vscode-codex-tabs\\work\\GroupyLinkTrace.log";

static void WriteLine(const wchar_t* text) {
    HANDLE file = CreateFileW(kLog, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD bytes = 0;
    WriteFile(file, text, static_cast<DWORD>(wcslen(text) * sizeof(wchar_t)), &bytes, nullptr);
    CloseHandle(file);
}

static bool IsGroupyStrip(HWND hwnd) {
    wchar_t klass[32] = {};
    RECT rect = {};
    if (GetClassNameW(hwnd, klass, _countof(klass)) <= 0 || wcscmp(klass, L"#32770") != 0) return false;
    if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd, &rect)) return false;
    return rect.top <= 2 && (rect.bottom - rect.top) <= 80 && (rect.right - rect.left) >= 300;
}

static bool IsRelevantMessage(UINT message) {
    switch (message) {
    case WM_MOUSEMOVE:
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_NCHITTEST:
    case WM_SETCURSOR:
    case WM_CAPTURECHANGED:
    case WM_CANCELMODE:
    case WM_ACTIVATE:
    case WM_ACTIVATEAPP:
    case WM_WINDOWPOSCHANGING:
    case WM_WINDOWPOSCHANGED:
    case WM_MOVE:
    case WM_SIZE:
        return true;
    default:
        return message >= WM_APP || message >= 0xC000;
    }
}

static void LogMessage(const wchar_t* source, HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (!IsGroupyStrip(hwnd) || !IsRelevantMessage(message)) return;
    auto procedure = reinterpret_cast<void*>(GetWindowLongPtrW(hwnd, GWLP_WNDPROC));
    MEMORY_BASIC_INFORMATION mbi = {};
    VirtualQuery(procedure, &mbi, sizeof(mbi));
    wchar_t module[MAX_PATH] = {};
    GetModuleFileNameW(reinterpret_cast<HMODULE>(mbi.AllocationBase), module, _countof(module));
    wchar_t position[96] = {};
    if (message >= WM_MOUSEFIRST && message <= WM_MOUSELAST) {
        _snwprintf_s(position, _countof(position), _TRUNCATE, L" x=%d y=%d", GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
    }
    wchar_t line[1152] = {};
    _snwprintf_s(line, _countof(line), _TRUNCATE,
                 L"%s strip=%p msg=0x%04X wp=%p lp=%p%s wndproc=%p moduleBase=%p module=%s\r\n",
                 source, hwnd, message, reinterpret_cast<void*>(wParam), reinterpret_cast<void*>(lParam), position,
                 procedure, mbi.AllocationBase, module);
    WriteLine(line);
}

extern "C" __declspec(dllexport) LRESULT CALLBACK GroupyLinkCallWndProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code >= 0 && lParam) {
        const CWPSTRUCT* message = reinterpret_cast<const CWPSTRUCT*>(lParam);
        LogMessage(L"send", message->hwnd, message->message, message->wParam, message->lParam);
    }
    return CallNextHookEx(g_callHook, code, wParam, lParam);
}

extern "C" __declspec(dllexport) LRESULT CALLBACK GroupyLinkGetMessageProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code >= 0 && lParam) {
        const MSG* message = reinterpret_cast<const MSG*>(lParam);
        LogMessage(L"queue", message->hwnd, message->message, message->wParam, message->lParam);
    }
    return CallNextHookEx(g_getMessageHook, code, wParam, lParam);
}

extern "C" __declspec(dllexport) BOOL WINAPI InstallLinkTrace(DWORD threadId) {
    if (g_callHook || g_getMessageHook) return FALSE;
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(&GroupyLinkCallWndProc), &module)) return FALSE;
    g_callHook = SetWindowsHookExW(WH_CALLWNDPROC, GroupyLinkCallWndProc, module, threadId);
    if (!g_callHook) return FALSE;
    g_getMessageHook = SetWindowsHookExW(WH_GETMESSAGE, GroupyLinkGetMessageProc, module, threadId);
    if (g_getMessageHook) return TRUE;
    UnhookWindowsHookEx(g_callHook);
    g_callHook = nullptr;
    return FALSE;
}

extern "C" __declspec(dllexport) void WINAPI RemoveLinkTrace() {
    if (g_callHook) UnhookWindowsHookEx(g_callHook);
    if (g_getMessageHook) UnhookWindowsHookEx(g_getMessageHook);
    g_callHook = nullptr;
    g_getMessageHook = nullptr;
}
