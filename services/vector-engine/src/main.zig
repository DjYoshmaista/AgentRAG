const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

// Error definitions for better error handling
const VectorError = error{
    DimensionMismatch,
    OutOfMemory,
    InvalidInput,
    IndexOutOfBounds,
};

/// A high-dimensional vector for similarity operations
const Vector = struct {
    id: []const u8,
    data: []f32,
    allocator: Allocator, // Store allocator for cleanup

    const Self = @This();

    /// Initialize a new vector with given dimensions
    pub fn init(allocator: Allocator, id: []const u8, dimensions: usize) !Self {
        const data = try allocator.alloc(f32, dimensions);
        errdefer allocator.free(data);
        
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);

        return Self{
            .id = owned_id,
            .data = data,
            .allocator = allocator,
        };
    }

    /// Clean up vector memory
    pub fn deinit(self: Self) void {
        self.allocator.free(self.data);
        self.allocator.free(self.id);
    }

    /// Calculate cosine similarity with another vector
    pub fn cosine_similarity(self: *const Self, other: *const Self) VectorError!f32 {
        if (self.data.len != other.data.len) {
            return VectorError.DimensionMismatch;
        }

        var dot_prod: f32 = 0.0; // Renamed to avoid shadowing
        var norm_a: f32 = 0.0;
        var norm_b: f32 = 0.0;

        for (self.data, other.data) |a, b| {
            dot_prod += a * b;
            norm_a += a * a;
            norm_b += b * b;
        }

        const magnitude = @sqrt(norm_a * norm_b);
        if (magnitude == 0.0) return 0.0;
        
        return dot_prod / magnitude;
    }

    /// Calculate dot product with another vector
    pub fn dot_product(self: *const Self, other: *const Self) VectorError!f32 {
        if (self.data.len != other.data.len) {
            return VectorError.DimensionMismatch;
        }

        var result: f32 = 0.0;
        for (self.data, other.data) |a, b| {
            result += a * b;
        }
        return result;
    }
};

const SearchResult = struct {
    vector: *const Vector,
    score: f32,

    /// Compare function for sorting search results by score (descending)
    pub fn compareByScore(_: void, lhs: SearchResult, rhs: SearchResult) bool {
        return lhs.score > rhs.score; // Higher scores first
    }
};

const VectorStore = struct {
    vectors: ArrayList(Vector),
    allocator: Allocator,

    const Self = @This();

    /// Initialize a new vector store
    pub fn init(allocator: Allocator) Self {
        return Self{
            .vectors = ArrayList(Vector){}, // Fixed initialization for 0.16.0-dev
            .allocator = allocator,
        };
    }

    /// Clean up all vectors and the store
    pub fn deinit(self: *Self) void {
        for (self.vectors.items) |vector| {
            vector.deinit();
        }
        self.vectors.deinit(self.allocator); // Pass allocator to deinit
    }

    /// Add a vector to the store
    pub fn addVector(self: *Self, vector: Vector) !void {
        try self.vectors.append(self.allocator, vector); // Pass allocator to append
    }

    /// Search for vectors similar to the query vector
    pub fn search(self: *const Self, query: *const Vector, k: usize) !ArrayList(SearchResult) {
        var results = ArrayList(SearchResult){};
        errdefer results.deinit(self.allocator);

        // Calculate similarities for all vectors
        for (self.vectors.items) |*vector| {
            const similarity = query.cosine_similarity(vector) catch 0.0;
            try results.append(self.allocator, SearchResult{
                .vector = vector,
                .score = similarity,
            });
        }

        // Sort by score using current Zig sorting API
        std.mem.sort(SearchResult, results.items, {}, SearchResult.compareByScore);

        // Truncate to top-k results
        if (results.items.len > k) {
            results.shrinkRetainingCapacity(k);
        }

        return results;
    }

    /// Get vector count
    pub fn count(self: *const Self) usize {
        return self.vectors.items.len;
    }
};

// Simplified server implementation
const VectorServer = struct {
    store: VectorStore,
    allocator: Allocator,
    address: std.net.Address,

    const Self = @This();

    pub fn init(allocator: Allocator, port: u16) !Self {
        return Self{
            .store = VectorStore.init(allocator),
            .allocator = allocator,
            .address = try std.net.Address.parseIp("0.0.0.0", port),
        };
    }

    pub fn deinit(self: *Self) void {
        self.store.deinit();
    }

    pub fn start(self: *Self) !void {
        var server = try self.address.listen(.{});
        defer server.deinit();

        print("Vector engine listening on {any}\n", .{self.address}); // Fixed format specifier

        while (true) {
            const client = server.accept() catch |err| {
                print("Failed to accept connection: {any}\n", .{err}); // Fixed format specifier
                continue;
            };

            // Handle connection (simplified for now)
            self.handleConnection(client) catch |err| {
                print("Error handling connection: {any}\n", .{err}); // Fixed format specifier
            };
        }
    }

    fn handleConnection(_: *Self, client: std.net.Server.Connection) !void {
        defer client.stream.close();

        var buffer: [4096]u8 = undefined;
        const bytes_read = try client.stream.read(&buffer);

        if (bytes_read == 0) return;

        // Define the response body
        const response_body = "{\"status\":\"vector_ok\"}";
        // Calculate the length of the body
        const body_len = response_body.len; // This will be 21

        // Create the full HTTP response with correct Content-Length
        // Using a formatted string to insert the correct length
        var response_buffer: [512]u8 = undefined; // Buffer large enough for the response
        const response = try std.fmt.bufPrint(
            &response_buffer,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ body_len, response_body }
        );

        _ = try client.stream.write(response);

        print("Processed vector request of {d} bytes (Response Body Length: {d})\n", .{bytes_read, body_len});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("Starting Vector Engine...\n", .{});

    // Initialize vector store
    var store = VectorStore.init(allocator);
    defer store.deinit();

    // Create sample vectors
    var v1 = try Vector.init(allocator, "vector1", 3);
    v1.data[0] = 1.0; v1.data[1] = 2.0; v1.data[2] = 3.0;

    var v2 = try Vector.init(allocator, "vector2", 3);
    v2.data[0] = 4.0; v2.data[1] = 5.0; v2.data[2] = 6.0;

    // Add vectors to store
    try store.addVector(v1);
    try store.addVector(v2);

    // Perform similarity search
    var results = try store.search(&v1, 5);
    defer results.deinit(allocator);

    print("Found {d} similar vectors\n", .{results.items.len}); // Fixed format specifier
    for (results.items) |result| {
        print("Vector ID: {s}, Score: {d:.3}\n", .{ result.vector.id, result.score }); // Fixed format specifier
    }

    // Start server
    var server = try VectorServer.init(allocator, 8080);
    defer server.deinit();

    try server.start();
}

// Tests using current testing patterns
test "vector operations" {
    const allocator = testing.allocator;

    var v1 = try Vector.init(allocator, "test1", 3);
    defer v1.deinit();
    v1.data[0] = 1.0; v1.data[1] = 0.0; v1.data[2] = 0.0;

    var v2 = try Vector.init(allocator, "test2", 3);
    defer v2.deinit();
    v2.data[0] = 0.0; v2.data[1] = 1.0; v2.data[2] = 0.0;

    const similarity = try v1.cosine_similarity(&v2);
    try testing.expectEqual(@as(f32, 0.0), similarity);

    const dot = try v1.dot_product(&v1);
    try testing.expectEqual(@as(f32, 1.0), dot);
}

test "vector store operations" {
    const allocator = testing.allocator;

    var store = VectorStore.init(allocator);
    defer store.deinit();

    var v1 = try Vector.init(allocator, "test", 2);
    defer v1.deinit();
    v1.data[0] = 1.0; v1.data[1] = 1.0;

    try store.addVector(v1);
    try testing.expectEqual(@as(usize, 1), store.count());
}
