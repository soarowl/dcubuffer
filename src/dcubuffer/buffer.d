module dcubuffer.buffer;

import std.bitmanip : swapEndian;
import std.string : toUpper;
import std.system : Endian, endian;
import std.traits : isArray, isBoolean, isIntegral, isFloatingPoint, isSomeChar, Unqual;

import dcubuffer.memory : xmalloc, xrealloc, xfree;
import dcubuffer.varint : isVar, Var;

//TODO remove
import std.stdio : writeln;

alias ForeachType(T) = typeof(T.init[0]);

enum canSwapEndianness(T) = isBoolean!T || isIntegral!T || isFloatingPoint!T
    || isSomeChar!T || (is(T == struct) && canSwapEndiannessImpl!T);

private bool canSwapEndiannessImpl(T)()
{
    static if (is(T == struct))
    {
        import std.traits : Fields;

        bool ret = true;
        foreach (field; Fields!T)
        {
            if (!canSwapEndianness!field)
                ret = false;
        }
        return ret;
    }
    else
    {
        return false;
    }
}

unittest
{

    static assert(canSwapEndianness!byte);
    static assert(canSwapEndianness!int);
    static assert(canSwapEndianness!double);
    static assert(canSwapEndianness!char);
    static assert(canSwapEndianness!dchar);

}

unittest
{

    static struct A
    {
    }

    static struct B
    {
        int a, b;
    }

    static class C
    {
    }

    static struct D
    {
        int a;
        B b;
    }

    static struct E
    {
        B b;
        C c;
    }

    static struct F
    {
        void a()
        {
        }

        float b;
    }

    static struct G
    {
        @property Object a()
        {
            return null;
        }
    }

    static struct H
    {
        ubyte[] a;
    }

    static struct I
    {
        int* a;
    }

    static assert(canSwapEndianness!A);
    static assert(canSwapEndianness!B);
    static assert(!canSwapEndianness!C);
    static assert(canSwapEndianness!D);
    static assert(!canSwapEndianness!E);
    static assert(canSwapEndianness!F);
    static assert(canSwapEndianness!G);
    static assert(!canSwapEndianness!H);
    static assert(!canSwapEndianness!I);

}

private union EndianSwapper(T) if (canSwapEndianness!T)
{

    enum builtInSwap = T.sizeof == 2 || T.sizeof == 4 || T.sizeof == 8;

    T value;
    void[T.sizeof] data;
    ubyte[T.sizeof] bytes;

    this(T value)
    {
        this.value = value;
    }

    this(void[] data)
    {
        this.data = data;
    }

    static if (T.sizeof == 2)
        ushort _swap;
    else static if (T.sizeof == 4)
        uint _swap;
    else static if (T.sizeof == 8)
        ulong _swap;

    void swap()
    {
        static if (builtInSwap)
            _swap = swapEndian(_swap);
        else static if (T.sizeof > 1)
        {
            import std.algorithm.mutation : swap;

            foreach (i; 0 .. T.sizeof >> 1)
            {
                swap(bytes[i], bytes[T.sizeof - i - 1]);
            }
        }
    }

}

unittest
{

    static struct Test
    {

        int a, b, c;

    }

    static assert(Test.sizeof == 12);

    EndianSwapper!Test swapper;
    swapper.value = Test(1, 2, 3);

    version (BigEndian)
        assert(swapper.bytes == [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3]);
    version (LittleEndian)
        assert(swapper.bytes == [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0]);

    swapper.swap();

    version (BigEndian)
        assert(swapper.bytes == [3, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0]);
    version (LittleEndian)
        assert(swapper.bytes == [0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0, 1]);

    assert(swapper.value == Test(3 << 24, 2 << 24, 1 << 24));

}

/**
 * Exception thrown when the buffer cannot read the requested
 * data.
 */
class BufferOverflowException : Exception
{

    this(string file = __FILE__, size_t line = __LINE__) pure nothrow @safe @nogc
    {
        super("The buffer's index has exceeded its length", file, line);
    }

}

static if (__traits(compiles, ()@nogc { throw new Exception(""); }))
    version = DIP1008;

/**
 * Buffer for writing and reading binary data.
 */
class Buffer
{

    private immutable size_t chunk;

    private void[] _data;
    private size_t _rindex, _windex;

    // Special variables for DCU reader/writer.
    private ubyte _compiler;
    private ubyte _platform;

    /**
	 * Creates a buffer specifying the chunk size.
	 * This should be the default constructor for re-used buffers and
	 * input buffers.
	 */
    this(size_t chunk) pure nothrow @trusted @nogc
    {
        this.chunk = chunk == 0 ? 1 : chunk;
        //_data = malloc(this.chunk);
        _data = xrealloc(_data.ptr, this.chunk);
    }

    ///
    pure nothrow @safe unittest
    {

        Buffer buffer = new Buffer(8);

        // 8 bytes allocated by the constructor
        assert(buffer.capacity == 8);

        // writing 4 bytes does not alter the capacity
        buffer.write(0);
        assert(buffer.capacity == 8);

        // writing 8 bytes requires a new allocation (because 4 + 8 is
        // higher than the current capacity of 8).
        // The new capacity is rounded up to the nearest multiple of the chunk size.
        buffer.write(0L);
        assert(buffer.capacity == 16);

    }

    /**
	 * Creates a buffer from an array of data.
	 * The chunk size is set to the size of the array.
	 */
    this(T)(in T[] data...) pure nothrow @trusted @nogc
            if (canSwapEndianness!T || is(T == void))
    {
        this(data.length * T.sizeof);
        _windex = _data.length;
        _data[0 .. $] = cast(void[]) data;

        updateProperties();
    }

    ///
    pure nothrow @safe unittest
    {

        Buffer buffer = new Buffer(cast(ubyte[])[1, 2, 3, 4]);
        assert(buffer.rindex == 0);
        assert(buffer.windex == 4);

        buffer = new Buffer([1, 2]);
        assert(buffer.rindex == 0);
        assert(buffer.windex == 8);

    }

    private void updateProperties() pure nothrow @trusted @nogc
    {
        auto first = cast(ubyte[]) _data[0 .. _windex];
        if (first.length >= 4) {
            _platform = first[1];
            _compiler = first[3];
        }
    }

    private void resize(size_t requiredSize) pure nothrow @trusted @nogc
    {
        immutable rem = requiredSize / chunk;
        immutable size = (requiredSize + chunk - 1) / chunk * chunk;
        _data = xrealloc(_data.ptr, size);
    }

    @property size_t rindex() pure nothrow @safe @nogc
    {
        return _rindex;
    }

    @property size_t windex() pure nothrow @safe @nogc
    {
        return _windex;
    }

    @property ubyte compiler() pure nothrow @safe @nogc
    {
        return _compiler;
    }

    @property void compiler(ubyte c) pure nothrow @safe @nogc
    {
        _compiler = c;
    }

    @property ubyte platform() pure nothrow @safe @nogc
    {
        return _platform;
    }

    @property void platform(ubyte p) pure nothrow @safe @nogc
    {
        _platform = p;
    }

    @property T[] data(T = void)() pure nothrow @trusted @nogc
            if ((canSwapEndianness!T || is(T == void)) && T.sizeof == 1)
    {
        return cast(T[]) _data[_rindex .. _windex];
    }

    @property T[] data(T)() pure nothrow @nogc
            if (canSwapEndianness!T && T.sizeof != 1)
    {
        return cast(T[]) _data[_rindex .. _windex];
    }

    /**
	 * Sets new data and resets the index.
	 */
    @property auto data(T)(in T[] data) pure nothrow @trusted @nogc
    {
        _rindex = 0;
        _windex = data.length * T.sizeof;
        if (_windex > _data.length)
            this.resize(_windex);
        _data[0 .. _windex] = cast(void[]) data;

        updateProperties();

        return data;
    }

    ///
    pure nothrow @trusted unittest
    {

        Buffer buffer = new Buffer(2);

        buffer.data = cast(ubyte[])[0, 0, 0, 1];
        assert(buffer.rindex == 0); // resetted when setting new data
        assert(buffer.windex == 4);
        version (BigEndian)
            assert(buffer.data!uint == [1]);
        version (LittleEndian)
            assert(buffer.data!uint == [1 << 24]);

        buffer.data = "hello";
        assert(buffer.rindex == 0);
        assert(buffer.windex == 5);
        assert(buffer.data == "hello");

    }

    /**
	 * Resets the buffer setting the index and its length to 0.
	 */
    void reset() pure nothrow @safe @nogc
    {
        _rindex = 0;
        _windex = 0;
    }

    /**
	 * Gets the size of the data allocated by the buffer.
	 */
    @property size_t capacity() pure nothrow @safe @nogc
    {
        return _data.length;
    }

    void back(size_t amount) pure nothrow @safe @nogc
    {
        assert(amount <= _rindex);
        _rindex -= amount;
    }

    // ----------
    // operations
    // ----------

    /**
	 * Check whether the data of the buffer is equals to
	 * the given array.
	 */
    bool opEquals(T)(in T[] data) pure nothrow @safe @nogc if (T.sizeof == 1)
    {
        return this.data!T == data;
    }

    /// ditto
    bool opEquals(T)(in T[] data) pure nothrow @nogc if (T.sizeof != 1)
    {
        return this.data!T == data;
    }

    ///
    pure nothrow @trusted unittest
    {

        Buffer buffer = new Buffer([1, 2, 3]);

        assert(buffer == [1, 2, 3]);
        version (BigEndian)
            assert(buffer == cast(ubyte[])[0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3]);
        version (LittleEndian)
            assert(buffer == cast(ubyte[])[1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0]);

    }

    // -----
    // write
    // -----

    private void need(size_t size) pure nothrow @safe @nogc
    {
        size += _windex;
        if (size > this.capacity)
            this.resize(size);
    }

    private void writeDataImpl(in void[] data) pure nothrow @trusted @nogc
    {
        immutable start = _windex;
        _windex += data.length;
        _data[start .. _windex] = data;
    }

    /**
	 * Writes data to the buffer and expands if it is not big enough.
	 */
    void writeData(in void[] data) pure nothrow @safe @nogc
    {
        this.need(data.length);
        this.writeDataImpl(data);
    }

    /**
	 * Writes data to buffer using the given endianness.
	 */
    void write(Endian endianness, T)(T value) pure nothrow @trusted @nogc
            if (canSwapEndianness!T)
    {
        EndianSwapper!T swapper = EndianSwapper!T(value);
        static if (endianness != endian && T.sizeof > 1)
            swapper.swap();
        this.writeData(swapper.data);
    }

    ///
    unittest
    {

        Buffer buffer = new Buffer(4);
        buffer.write!(Endian.bigEndian)(4);
        buffer.write!(Endian.littleEndian)(4);
        assert(buffer.data!ubyte == [0, 0, 0, 4, 4, 0, 0, 0]);

    }

    /**
	 * Writes data to the buffer using the system's endianness.
	 */
    void write(T)(T value) pure nothrow @safe @nogc if (canSwapEndianness!T)
    {
        this.write!(endian, T)(value);
    }

    ///
    pure nothrow @safe unittest
    {

        Buffer buffer = new Buffer(5);
        buffer.write(ubyte(5));
        buffer.write(10);
        version (BigEndian)
            assert(buffer.data!ubyte == [5, 0, 0, 0, 10]);
        version (LittleEndian)
            assert(buffer.data!ubyte == [5, 10, 0, 0, 0]);

    }

    /**
	 * Writes an array using the given endianness.
	 */
    void write(Endian endianness, T)(in T value) pure nothrow @trusted @nogc
            if (isArray!T && (is(ForeachType!T : void) || canSwapEndianness!(ForeachType!T)))
    {
        static if (endianness == endian || T.sizeof <= 1)
        {
            this.writeData(value);
        }
        else
        {
            this.need(value.length * ForeachType!T.sizeof);
            foreach (element; value)
            {
                auto swapper = EndianSwapper!(ForeachType!T)(element);
                swapper.swap();
                this.writeDataImpl(swapper.data);
            }
        }
    }

    ///
    pure nothrow @safe unittest
    {

        Buffer buffer = new Buffer(8);
        buffer.write!(Endian.bigEndian)([1, 2, 3]);
        assert(buffer.capacity == 16);
        assert(buffer.data!ubyte == [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3]);

        buffer.reset();
        buffer.write!(Endian.littleEndian)(cast(short[])[-2, 2]);
        assert(buffer.data!ubyte == [254, 255, 2, 0]);

        buffer.reset();
        buffer.write!(Endian.bigEndian, wstring)("test"w);
        assert(buffer.data!ubyte == [0, 't', 0, 'e', 0, 's', 0, 't']);

    }

    /**
	 * Writes an array using the system's endianness.
	 */
    void write(T)(in T value) pure nothrow @safe @nogc
            if (isArray!T && (is(ForeachType!T : void) || canSwapEndianness!(ForeachType!T)))
    {
        this.write!(endian, T)(value);
    }

    ///
    pure nothrow @safe unittest
    {

        Buffer buffer = new Buffer(8);
        buffer.write(cast(ubyte[])[1, 2, 3, 4]);
        buffer.write("test");
        assert(buffer.data!ubyte == [1, 2, 3, 4, 't', 'e', 's', 't']);
        buffer.write([1, 2]);
        version (BigEndian)
            assert(buffer.data!ubyte == [
            1, 2, 3, 4, 't', 'e', 's', 't', 0, 0, 0, 1, 0, 0, 0, 2
        ]);
        version (LittleEndian)
            assert(buffer.data!ubyte == [
            1, 2, 3, 4, 't', 'e', 's', 't', 1, 0, 0, 0, 2, 0, 0, 0
        ]);

    }

    /**
	 * Writes a varint.
	 */
    void writeVar(T)(T value) pure nothrow @safe @nogc
            if (isIntegral!T && T.sizeof > 1)
    {
        Var!T.encode(this, value);
    }

    /// ditto
    void write(T : Var!B, B)(B value) pure nothrow @safe @nogc
    {
        this.writeVar!(T.Base)(value);
    }

    ///
    pure nothrow @safe unittest
    {

        import dcubuffer.varint;

        Buffer buffer = new Buffer(8);
        buffer.writeVar(1);
        buffer.write!varuint(1);
        assert(buffer.data!ubyte == [2, 2]);

    }

    /**
	 * Writes data at the given index.
	 */
    void write(alias E = endian, T)(in T value, size_t index) pure nothrow @trusted @nogc
            if (is(typeof(E) : Endian) && (canSwapEndianness!T || is(T == void)
                || isArray!T && (canSwapEndianness!(ForeachType!T) || is(ForeachType!T == void)))
                || is(E == struct) && isVar!E)
    {
        void[] shift = xmalloc(this.data.length - index);
        shift[0 .. $] = this.data[index .. $];
        _windex = _rindex + index;
        this.write!E(value);
        this.writeData(shift);
        xfree(shift.ptr);
    }

    /// ditto
    pure @trusted unittest
    {

        import dcubuffer.varint;

        Buffer buffer = new Buffer([1, 2, 3]);
        buffer.write(0, 0);
        assert(buffer.data!int == [0, 1, 2, 3]);

        buffer.data = cast(ubyte[])[0, 1, 2, 5];
        buffer.write(cast(ubyte[])[3, 4], 3);
        assert(buffer.data!ubyte == [0, 1, 2, 3, 4, 5]);

        buffer.data = cast(ubyte[])[1, 1, 2];
        buffer.read!ubyte();
        buffer.write!varuint(118485, 1);
        assert(buffer.data!ubyte == [1, 0xAB, 0x76, 0xE, 2]);

        buffer.data = "hellld";
        buffer.write('o', 4);
        buffer.write(" wor", 5);
        assert(buffer.data == "hello world");

    }

    // ----
    // read
    // ----

    /**
	 * Indicates whether an array of length `size` or the given type
	 * can be read without any exceptions thrown.
	 */
    bool canRead(size_t size) pure nothrow @safe @nogc
    {
        return _rindex + size <= _windex;
    }

    /// ditto
    bool canRead(T)() pure nothrow @safe @nogc if (canSwapEndianness!T)
    {
        return this.canRead(T.sizeof);
    }

    ///
    unittest
    {

        import dcubuffer.varint;

        Buffer buffer = new Buffer(cast(ubyte[])[128, 200, 3]);
        assert(buffer.canRead(2));
        assert(buffer.canRead(3));
        assert(!buffer.canRead(4));
        assert(buffer.canRead!byte());
        assert(buffer.canRead!short());
        assert(!buffer.canRead!int());

    }

    /**
	 * Reads the amount of data requested.
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    void[] readData(size_t size) pure @safe
    {
        if (!this.canRead(size))
            throw new BufferOverflowException();
        _rindex += size;
        return _data[_rindex - size .. _rindex];
    }

    ///
    pure @safe unittest
    {

        Buffer buffer = new Buffer([1]);
        assert(buffer.read!int() == 1);
        try
        {
            buffer.read!int();
            assert(0);
        }
        catch (BufferOverflowException ex)
        {
            assert(ex.file == __FILE__);
        }

    }

    /**
	 * Reads a value with the given endianness.
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    T read(Endian endianness, T)() pure @trusted if (canSwapEndianness!T)
    {
        EndianSwapper!T swapper = EndianSwapper!T(this.readData(T.sizeof));
        static if (endianness != endian)
            swapper.swap();
        return swapper.value;
    }

    ///
    pure @safe unittest
    {

        Buffer buffer = new Buffer(cast(ubyte[])[0, 0, 0, 1, 1, 0]);
        assert(buffer.read!(Endian.bigEndian, int)() == 1);
        assert(buffer.read!(Endian.littleEndian, short)() == 1);

    }

    /**
	 * Reads a value using the system's endianness.
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    T read(T)() pure @safe if (canSwapEndianness!T)
    {
        return this.read!(endian, T)();
    }

    ///
    pure @safe unittest
    {

        version (BigEndian) Buffer buffer = new Buffer([0, 0, 0, 1]);
        version (LittleEndian) Buffer buffer = new Buffer([1, 0, 0, 0]);
        assert(buffer.read!int() == 1);

    }

    /**
	 * Reads an array using the given endianness.
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    T read(Endian endianness, T)(size_t length) pure @trusted
            if (isArray!T && (is(ForeachType!T : void) || canSwapEndianness!(ForeachType!T)))
    {
        T ret = cast(T) this.readData(length * ForeachType!T.sizeof);
        static if (endianness != endian && T.sizeof != 1)
        {
            foreach (ref element; ret)
            {
                EndianSwapper!(ForeachType!T) swapper = EndianSwapper!(ForeachType!T)(element);
                swapper.swap();
                element = swapper.value;
            }
        }
        return ret;
    }

    ///
    pure @safe unittest
    {

        Buffer buffer = new Buffer(16);

        buffer.write!(Endian.bigEndian)(16);
        buffer.write!(Endian.bigEndian)(32);
        buffer.write!(Endian.littleEndian)(32);
        buffer.write!(Endian.littleEndian)(16);
        assert(buffer.data!ubyte == [
            0, 0, 0, 16, 0, 0, 0, 32, 32, 0, 0, 0, 16, 0, 0, 0
        ]);

        assert(buffer.read!(Endian.bigEndian, int[])(2) == [16, 32]);
        assert(buffer.read!(Endian.littleEndian, int[])(2) == [32, 16]);

    }

    /**
	 * Reads an array using the system's endianness.
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    T read(T)(size_t size) pure @trusted
            if (isArray!T && (is(ForeachType!T : void) || canSwapEndianness!(ForeachType!T)))
    {
        return this.read!(endian, T)(size);
    }

    ///
    pure @safe unittest
    {

        Buffer buffer = new Buffer("!hello");
        assert(buffer.read!(ubyte[])(1) == [33]);
        assert(buffer.read!string(5) == "hello");

        buffer.data = [1, 2, 3];
        version (BigEndian)
            assert(buffer.data!ubyte == [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3]);
        version (LittleEndian)
            assert(buffer.data!ubyte == [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0]);
        assert(buffer.read!(int[])(3) == [1, 2, 3]);

    }

    /**
	 * Reads a varint.
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    T readVar(T)() pure @safe if (isIntegral!T && T.sizeof > 1)
    {
        return Var!T.decode!true(this);
    }

    /// ditto
    B read(T : Var!B, B)() pure @safe
    {
        return this.readVar!B();
    }

    ///
    pure @safe unittest
    {

        import dcubuffer.varint;

        Buffer buffer = new Buffer(cast(ubyte[])[2, 2]);
        assert(buffer.readVar!int() == 1);
        assert(buffer.read!varuint() == 1);

    }

    // ----
    // peek
    // ----

    /**
	 * Peeks some data (read it but without changing the buffer's index).
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    void[] peekData(size_t size) pure
    {
        if (!this.canRead(size))
            throw new BufferOverflowException();
        return _data[_rindex .. _rindex + size];
    }

    unittest
    {

        Buffer buffer = new Buffer([1]);
        assert(buffer.rindex == 0);
        buffer.peekData(4);
        assert(buffer.rindex == 0);

    }

    /**
	 * Peeks a value using the given endianness.
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    T peek(Endian endianness, T)() pure @trusted if (canSwapEndianness!T)
    {
        EndianSwapper!T swapper = EndianSwapper!T(this.peekData(T.sizeof));
        static if (endianness != endian)
            swapper.swap();
        return swapper.value;
    }

    ///
    pure @safe unittest
    {

        Buffer buffer = new Buffer(cast(ubyte[])[0, 0, 0, 1]);
        assert(buffer.peek!(Endian.bigEndian, int)() == 1);
        assert(buffer.peek!(Endian.littleEndian, int)() == 1 << 24);
        assert(buffer.peek!(Endian.bigEndian, short)() == 0);

    }

    /**
	 * Peeks some data using the system's endianness.
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    T peek(T)() pure @safe if (canSwapEndianness!T)
    {
        return this.peek!(endian, T)();
    }

    ///
    pure @safe unittest
    {

        Buffer buffer = new Buffer([1, 2]);
        assert(buffer.peek!int() == 1);
        assert(buffer.rindex == 0);
        assert(buffer.peek!int() == buffer.read!int());
        assert(buffer.rindex == 4);
        assert(buffer.peek!int() == 2);

    }

    /**
	 * Peeks a varint.
	 * Throws: BufferOverflowException if there isn't enough data to read.
	 */
    T peekVar(T)() pure @safe if (isIntegral!T && T.sizeof > 1)
    {
        return Var!T.decode!false(this);
    }

    /// ditto
    B peek(T : Var!B, B)() pure @safe
    {
        return this.peekVar!B();
    }

    ///
    pure @safe unittest
    {

        import dcubuffer.varint;

        Buffer buffer = new Buffer(cast(ubyte[])[2]);
        assert(buffer.peekVar!int() == 1);
        assert(buffer.peek!varuint() == 1);

    }

    // -----------
    // destruction
    // -----------

    void free() pure nothrow @nogc
    {
        xfree(_data.ptr);
    }

    /*void __xdtor() pure nothrow @nogc {
		this.free();
	}*/

    ~this() pure nothrow @nogc
    {
        this.free();
    }

}

///
unittest
{

    import dcubuffer.memory : xalloc;

    // a buffer can be garbage collected
    Buffer gc = new Buffer(16);

    // or manually allocated
    // alloc is a function provided by the dcubuffer.memory module
    Buffer b = xalloc!Buffer(16);

    // the memory is realsed with free, which is called by the garbage
    // collector or by the `free` function in the `dcubuffer.memory` module
    xfree(b);

}

unittest
{

    import dcubuffer.memory : xalloc;

    void[] data = xmalloc(923);

    auto buffer = xalloc!Buffer(1024);
    assert(buffer.windex == 0);

    buffer.writeData(data);
    assert(buffer.rindex == 0);
    assert(buffer.windex == 923);
    assert(buffer.capacity == 1024);

    buffer.writeData(data);
    assert(buffer.windex == 1846);
    assert(buffer.capacity == 2048);

    data = xrealloc(data.ptr, 1);

    buffer.data = data;
    assert(buffer.windex == 1);
    assert(buffer.capacity == 2048);

    data = xrealloc(data.ptr, 2049);

    buffer.data = data;
    assert(buffer.windex == 2049);
    assert(buffer.capacity == 3072);

    xfree(data.ptr);
    xfree(buffer);

}
