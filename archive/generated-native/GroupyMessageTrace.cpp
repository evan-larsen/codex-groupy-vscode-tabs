// Short-lived diagnostic hook for the stable Groupy controller thread.
#include <windows.h>

static HHOOK g_hook = nullptr;
static const char* kLogPath = "C:\\Users\\evanl\\Documents\\groupy-vscode-codex-tabs\\work\\GroupyMessageTrace.log";

static void LogMessage(const CWPSTRUCT* message) {
    if (message->message != WM_COMMAND && message->message != WM_HOTKEY &&
        message->message < WM_APP && message->message < 0xC000) return;

    char line[160] = {};
    wsprintfA(line, "hwnd=%p msg=0x%04X wp=%p lp=%p\r\n", message->hwnd, message->message,
              (void*)message->wParam, (void*)message->lParam);
    HANDLE file = CreateFileA(kLogPath, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line, (DWORD)lstrlenA(line), &written, nullptr);
    // In this installed session GP_UPDTAB2 is 0xC2DA. Capture the second argument while the
    // receiving Groupy thread still has it alive; it may be an HWND rather than a data pointer.
    if (message->message == 0xC2DA && message->lParam && IsWindow((HWND)message->lParam)) {
        char className[64] = {};
        char title[160] = {};
        GetClassNameA((HWND)message->lParam, className, (int)sizeof(className));
        GetWindowTextA((HWND)message->lParam, title, (int)sizeof(title));
        wsprintfA(line, "  argument-window class=%s title=%s\r\n", className, title);
        WriteFile(file, line, (DWORD)lstrlenA(line), &written, nullptr);
    }
    CloseHandle(file);
}

extern "C" __declspec(dllexport) LRESULT CALLBACK GroupyCallWndProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code >= 0 && lParam) LogMessage((const CWPSTRUCT*)lParam);
    return CallNextHookEx(nullptr, code, wParam, lParam);
}

extern "C" __declspec(dllexport) BOOL WINAPI InstallMessageTrace(DWORD threadId) {
    if (g_hook) return FALSE;
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)&GroupyCallWndProc, &module)) return FALSE;
    g_hook = SetWindowsHookExW(WH_CALLWNDPROC, GroupyCallWndProc, module, threadId);
    return g_hook != nullptr;
}

extern "C" __declspec(dllexport) void WINAPI RemoveMessageTrace() {
    if (g_hook) UnhookWindowsHookEx(g_hook);
    g_hook = nullptr;
}
