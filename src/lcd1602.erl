%%%-------------------------------------------------------------------
%%% @doc LCD1602 driver over I2C (PCF8574 backpack).
%%%
%%% Drives a standard 16x2 HD44780 LCD via the common PCF8574 I2C
%%% I/O expander backpack. Uses i2c_bus from atomvm_lib.
%%%
%%% PCF8574 pin mapping (directly drives HD44780):
%%%   P0 = RS, P1 = RW, P2 = EN, P3 = Backlight
%%%   P4 = D4, P5 = D5, P6 = D6, P7 = D7
%%%
%%% Usage:
%%%   {ok, LCD} = lcd1602:start(#{sda => 8, scl => 9}),
%%%   lcd1602:clear(LCD),
%%%   lcd1602:write_string(LCD, 0, 0, "Hello World!"),
%%%   lcd1602:write_string(LCD, 1, 0, "Line 2").
%%% @end
%%%-------------------------------------------------------------------
-module(lcd1602).

-export([start/1, stop/1, clear/1, home/1,
         set_cursor/3, write_string/4, backlight/2]).

-define(LCD_ADDR, 16#27).

%% HD44780 commands
-define(CMD_CLEAR, 16#01).
-define(CMD_HOME, 16#02).
-define(CMD_ENTRY_MODE, 16#06).
-define(CMD_DISPLAY_ON, 16#0C).
-define(CMD_FUNCTION_SET, 16#28).  %% 4-bit, 2 lines, 5x8
-define(CMD_SET_DDRAM, 16#80).

%% PCF8574 control bits
-define(RS, 16#01).   %% P0: Register Select (0=cmd, 1=data)
-define(RW, 16#02).   %% P1: Read/Write (always 0 for write)
-define(EN, 16#04).   %% P2: Enable
-define(BL, 16#08).   %% P3: Backlight

-record(lcd, {
    bus :: pid(),
    addr :: integer(),
    backlight :: integer()
}).

%% @doc Start the LCD. Options: #{sda => GPIO, scl => GPIO, addr => 16#27}.
-spec start(map()) -> {ok, #lcd{}} | {error, term()}.
start(Options) ->
    Addr = maps:get(addr, Options, ?LCD_ADDR),
    I2cOpts = #{
        sda => maps:get(sda, Options),
        scl => maps:get(scl, Options),
        freq_hz => maps:get(freq_hz, Options, 100000)
    },
    case i2c_bus:start(I2cOpts) of
        {ok, Bus} ->
            LCD = #lcd{bus = Bus, addr = Addr, backlight = ?BL},
            ok = init_display(LCD),
            {ok, LCD};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Stop the LCD and release the I2C bus.
stop(#lcd{bus = Bus}) ->
    i2c_bus:stop(Bus).

%% @doc Clear the display.
clear(LCD) ->
    send_command(LCD, ?CMD_CLEAR),
    timer:sleep(2).

%% @doc Move cursor to home position.
home(LCD) ->
    send_command(LCD, ?CMD_HOME),
    timer:sleep(2).

%% @doc Set cursor position. Row 0-1, Col 0-15.
set_cursor(LCD, Row, Col) ->
    Offset = case Row of
        0 -> 16#00;
        1 -> 16#40;
        _ -> 16#00
    end,
    send_command(LCD, ?CMD_SET_DDRAM bor (Offset + Col)).

%% @doc Write a string at the given row and column.
write_string(LCD, Row, Col, String) ->
    set_cursor(LCD, Row, Col),
    lists:foreach(fun(Char) -> send_data(LCD, Char) end, String).

%% @doc Control backlight. true = on, false = off.
backlight(LCD = #lcd{}, On) ->
    BL = case On of true -> ?BL; false -> 0 end,
    LCD1 = LCD#lcd{backlight = BL},
    %% Send a no-op to update backlight state
    i2c_bus:write_bytes(LCD1#lcd.bus, LCD1#lcd.addr, <<BL>>),
    LCD1.



%%%===================================================================
%%% Internal
%%%===================================================================

init_display(LCD) ->
    %% HD44780 initialization sequence for 4-bit mode
    timer:sleep(50),
    %% Send 0x03 three times to ensure 8-bit mode first
    write_4bits(LCD, 16#03 bsl 4),
    timer:sleep(5),
    write_4bits(LCD, 16#03 bsl 4),
    timer:sleep(5),
    write_4bits(LCD, 16#03 bsl 4),
    timer:sleep(1),
    %% Switch to 4-bit mode
    write_4bits(LCD, 16#02 bsl 4),
    timer:sleep(1),
    %% Now in 4-bit mode, configure display
    send_command(LCD, ?CMD_FUNCTION_SET),
    send_command(LCD, ?CMD_DISPLAY_ON),
    send_command(LCD, ?CMD_CLEAR),
    timer:sleep(2),
    send_command(LCD, ?CMD_ENTRY_MODE),
    ok.

%% Send a command byte (RS=0)
send_command(LCD, Cmd) ->
    send_byte(LCD, Cmd, 0).

%% Send a data byte (RS=1)
send_data(LCD, Data) ->
    send_byte(LCD, Data, ?RS).

%% Send a byte in two 4-bit nibbles
send_byte(LCD, Byte, Mode) ->
    HighNibble = (Byte band 16#F0) bor Mode bor LCD#lcd.backlight,
    LowNibble = ((Byte bsl 4) band 16#F0) bor Mode bor LCD#lcd.backlight,
    write_4bits(LCD, HighNibble),
    write_4bits(LCD, LowNibble).

%% Pulse the Enable pin to latch a 4-bit nibble
write_4bits(LCD, Value) ->
    Addr = LCD#lcd.addr,
    Bus = LCD#lcd.bus,
    %% EN high
    i2c_bus:write_bytes(Bus, Addr, <<(Value bor ?EN)>>),
    timer:sleep(1),
    %% EN low (latch)
    i2c_bus:write_bytes(Bus, Addr, <<(Value band (bnot ?EN))>>),
    timer:sleep(1).
