const data = @import("data");
const io = @import("io");

pub fn sayHello() void {
    io.print(data.hello_world);
}
