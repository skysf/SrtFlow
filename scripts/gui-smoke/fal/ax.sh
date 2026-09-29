#!/usr/bin/env bash
# 用 System Events 的辅助功能接口读 / 点冒烟 App 窗口里的东西（AXPress，不走鼠标事件、不进 NSControl 的跟踪循环）
# SwiftUI 的按钮自己没有名字，文字在它里面的 static text 上。
# 用法：ax.sh texts | click <按钮的 accessibilityIdentifier>
PROC=SrtFlowFalSmoke
case "$1" in
  texts)
    osascript <<OSA 2>&1
tell application "System Events" to tell process "$PROC"
  set out to ""
  repeat with w in windows
    set els to entire contents of w
    repeat with el in els
      try
        set r to role of el
        if r is "AXStaticText" then set out to out & (value of el) & " | "
      end try
    end repeat
  end repeat
  return out
end tell
OSA
    ;;
  click)
    osascript <<OSA 2>&1
tell application "System Events" to tell process "$PROC"
  repeat with w in windows
    set els to entire contents of w
    repeat with el in els
      try
        if role of el is "AXButton" then
          set ident to ""
          try
            set ident to (value of attribute "AXIdentifier" of el)
          end try
          if ident is "$2" then
            click el
            return "clicked $2"
          end if
        end if
      end try
    end repeat
  end repeat
  return "no button $2"
end tell
OSA
    ;;
  settings)
    osascript -e 'tell application "System Events" to tell process "'$PROC'" to click menu item "Settings…" of menu 1 of menu bar item 2 of menu bar 1' 2>&1
    ;;
  setvalue)
    # ax.sh setvalue <identifier> <值>
    osascript <<OSA 2>&1
tell application "System Events" to tell process "$PROC"
  repeat with w in windows
    set els to entire contents of w
    repeat with el in els
      try
        set ident to ""
        try
          set ident to (value of attribute "AXIdentifier" of el)
        end try
        if ident is "$2" then
          set focused of el to true
          set value of el to "$3"
          return "set $2"
        end if
      end try
    end repeat
  end repeat
  return "no field $2"
end tell
OSA
    ;;
  confirm)
    osascript <<OSA 2>&1
tell application "System Events" to tell process "$PROC"
  repeat with w in windows
    set els to entire contents of w
    repeat with el in els
      try
        set ident to ""
        try
          set ident to (value of attribute "AXIdentifier" of el)
        end try
        if ident is "$2" then
          perform action "AXConfirm" of el
          return "confirmed $2"
        end if
      end try
    end repeat
  end repeat
  return "no field $2"
end tell
OSA
    ;;
esac
