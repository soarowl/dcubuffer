module dcubuffer.varint;

import std.traits : isIntegral, isSigned, isUnsigned, Unsigned;
import std.bitmanip;
import dcubuffer.buffer : Buffer;

enum isVar(T) = is(T == Var!V, V);

// debug
import std.stdio : writeln;

unittest
{

    static assert(isVar!varshort);
    static assert(!isVar!short);

}

/**
 * Utility container for reading and writing signed and unsigned
 * varints from Google's protocol buffer.
 */
align(1) union U7
{
align(1):
    ubyte all;
    mixin(bitfields!(uint, "flag", 1, uint, "value", 7,));
}

align(1) union U14
{
align(1):
    ushort all;
    mixin(bitfields!(uint, "flag", 2, uint, "value", 14,));
}

// padded, compiler required!!!
align(1) union U21
{
align(1):
    ubyte[3] all;
    mixin(bitfields!(uint, "flag", 3, uint, "value", 21, uint, "", 8));
}

align(1) union U28
{
align(1):
    uint all;
    mixin(bitfields!(uint, "flag", 4, uint, "value", 28,));
}

align(1) struct U32
{
align(1):
    ubyte flag;
    uint value;
}

align(1) struct U64
{
align(1):
    ubyte flag;
    ulong value;
}

align(1) union I7
{
align(1):
    ubyte all;
    mixin(bitfields!(uint, "flag", 1, int, "value", 7,));
}

align(1) union I14
{
align(1):
    ushort all;
    mixin(bitfields!(uint, "flag", 2, int, "value", 14,));
}

// padded, compiler required!!!
align(1) union I21
{
align(1):
    ubyte[3] all;
    mixin(bitfields!(uint, "flag", 3, int, "value", 21, uint, "", 8));
}

align(1) union I28
{
align(1):
    uint all;
    mixin(bitfields!(uint, "flag", 4, int, "value", 28,));
}

align(1) struct I32
{
align(1):
    ubyte flag;
    int value;
}

align(1) struct I64
{
align(1):
    ubyte flag;
    long value;
}

struct Var(T) if (isIntegral!T)
{

    alias Base = T;

    static if (isSigned!T)
        private alias U = Unsigned!T;
    else
        private enum size_t limit = T.sizeof * 8 / 7 + 1;

    @disable this();

    static void encode(Buffer buffer, T value) pure nothrow @safe @nogc
    {
        static if (isUnsigned!T)
        {
            if (value <= 127)
            {
                U7 u;
                u.flag = 0;
                u.value = cast(uint) value;
                buffer.write!ubyte(u.all);
            }
            else if (value <= 16383)
            {
                U14 u;
                u.flag = 1;
                u.value = cast(uint) value;
                buffer.write!ushort(u.all);
            }
            else if (value <= 2097151)
            {
                U21 u;
                u.flag = 3;
                u.value = cast(uint) value;
                buffer.writeData(u.all);
            }
            else if (value <= 268435455)
            {
                U28 u;
                u.flag = 7;
                u.value = cast(uint) value;
                buffer.write!uint(u.all);
            }
            else if (value <= 4294967295)
            {
                U32 u;
                u.flag = 0x5F;
                u.value = cast(uint) value;
                buffer.write!ubyte(u.flag);
                buffer.write!uint(u.value);
            }
            else
            {
                U64 u;
                u.flag = 0xFF;
                u.value = value;
                buffer.write!ubyte(u.flag);
                buffer.write!ulong(u.value);
            }
        }
        else
        {
            if (value >= -64 && value <= 63)
            {
                I7 i;
                i.flag = 0;
                i.value = cast(int) value;
                buffer.write!ubyte(i.all);
            }
            else if (value >= -8192 && value <= 8191)
            {
                I14 i;
                i.flag = 1;
                i.value = cast(int) value;
                buffer.write!ushort(i.all);
            }
            else if (value >= -1048576 && value <= 1048575)
            {
                I21 i;
                i.flag = 3;
                i.value = cast(int) value;
                buffer.writeData(i.all);
            }
            else if (value >= -134217728 && value <= 134217727)
            {
                I28 i;
                i.flag = 7;
                i.value = cast(int) value;
                buffer.write!uint(i.all);
            }
            else if (value >= -2147483648 && value <= 2147483647)
            {
                I32 i;
                i.flag = 0x5F;
                i.value = cast(int) value;
                buffer.write!ubyte(i.flag);
                buffer.write!int(i.value);
            }
            else
            {
                I64 i;
                i.flag = 0xFF;
                i.value = value;
                buffer.write!ubyte(i.flag);
                buffer.write!long(i.value);
            }
        }
    }

    static T decode(bool consume)(Buffer buffer) pure @safe
    {
        size_t count = 0;
        static if (!consume)
            scope (success)
                buffer.back(count);
        return decodeImpl(buffer, count);
    }

    static T decodeImpl(Buffer buffer, ref size_t count) pure @safe
    {
        static if (isUnsigned!T)
        {
            scope (failure)
                buffer.back(count);

            ubyte tag = buffer.peek!ubyte();

            if ((tag & 1) == 0)
            {
                tag = buffer.read!ubyte();
                count++;
                U7 u;
                u.all = tag;
                return cast(T) u.value;
            }

            if ((tag & 3) == 1)
            {
                auto value = buffer.read!ushort();
                count += ushort.sizeof;
                U14 u;
                u.all = value;
                return cast(T) u.value;
            }

            if ((tag & 7) == 3)
            {
                U21 u;
                for (size_t i = 0; i < 3; i++)
                {
                    u.all[i] = buffer.read!ubyte();
                    count++;
                }
                return cast(T) u.value;
            }

            if ((tag & 15) == 7)
            {
                auto value = buffer.read!uint();
                count += uint.sizeof;
                U28 u;
                u.all = value;
                return cast(T) u.value;
            }

            if (tag == 0x5F)
            {
                U32 u;
                u.flag = buffer.read!ubyte();
                count++;
                u.value = buffer.read!uint();
                count += uint.sizeof;
                return cast(T) u.value;
            }

            if (tag == 0xFF)
            {
                U64 u;
                u.flag = buffer.read!ubyte();
                count++;
                u.value = buffer.read!ulong();
                count += ulong.sizeof;
                return cast(T) u.value;
            }

            assert(0);
        }
        else
        {
            scope (failure)
                buffer.back(count);

            ubyte tag = buffer.peek!ubyte();

            if ((tag & 1) == 0)
            {
                tag = buffer.read!ubyte();
                count++;
                I7 i;
                i.all = tag;
                return cast(T) i.value;
            }

            if ((tag & 3) == 1)
            {
                auto value = buffer.read!ushort();
                count += ushort.sizeof;
                I14 i;
                i.all = value;
                return cast(T) i.value;
            }

            if ((tag & 7) == 3)
            {
                I21 i21;
                for (size_t i = 0; i < 3; i++)
                {
                    i21.all[i] = buffer.read!ubyte();
                    count++;
                }
                return cast(T) i21.value;
            }

            if ((tag & 15) == 7)
            {
                auto value = buffer.read!uint();
                count += uint.sizeof;
                I28 i;
                i.all = value;
                return cast(T) i.value;
            }

            if (tag == 0x5F)
            {
                I32 i;
                i.flag = buffer.read!ubyte();
                count++;
                i.value = buffer.read!int();
                count += int.sizeof;
                return cast(T) i.value;
            }

            if (tag == 0xFF)
            {
                I64 i;
                i.flag = buffer.read!ubyte();
                count++;
                i.value = buffer.read!long();
                count += long.sizeof;
                return cast(T) i.value;
            }

            assert(0);
        }
    }

}

alias varbyte = Var!byte;

alias varubyte = Var!ubyte;

alias varshort = Var!short;

alias varushort = Var!ushort;

alias varint = Var!int;

alias varuint = Var!uint;

alias varlong = Var!long;

alias varulong = Var!ulong;

unittest
{

    Buffer buffer = new Buffer(16);

    varint.encode(buffer, 0);
    assert(buffer.data!ubyte == [0]);

    buffer.reset();
    varshort.encode(buffer, -1);
    varint.encode(buffer, 1);
    varint.encode(buffer, -2);
    assert(buffer.data!ubyte == [0xFE, 2, 0xFC]);

    buffer.reset();
    varint.encode(buffer, 2147483647);
    varint.encode(buffer, -2147483648);
    assert(buffer.data!ubyte == [95, 255, 255, 255, 127, 95, 0, 0, 0, 128]);

    assert(varint.decode!true(buffer) == 2147483647);
    assert(varint.decode!true(buffer) == -2147483648);

    buffer.data = cast(ubyte[])[0xFE, 2, 0xFC];
    assert(varint.decode!false(buffer) == -1);
    assert(varint.decode!true(buffer) == -1);
    assert(varint.decode!true(buffer) == 1);
    assert(varint.decode!true(buffer) == -2);

    varuint.encode(buffer, 1);
    varuint.encode(buffer, 2);
    varuint.encode(buffer, uint.max);
    assert(buffer.data!ubyte == [2, 4, 95, 255, 255, 255, 255]);
    assert(varushort.decode!true(buffer) == 1);
    assert(varuint.decode!true(buffer) == 2);
    assert(varulong.decode!true(buffer) == uint.max);

    // limit

    buffer.data = cast(ubyte[])[95, 255, 255, 255, 255, 255];
    varuint.decode!true(buffer);
    assert(buffer.data!ubyte == [255]);

    // exception

    import dcubuffer.buffer : BufferOverflowException;

    buffer.data = cast(ubyte[])[95, 255, 255, 255];
    try
    {
        varuint.decode!true(buffer);
        assert(0);
    }
    catch (BufferOverflowException)
    {
        assert(buffer.data!ubyte == [95, 255, 255, 255]);
    }

}
