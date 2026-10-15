// Verification-only fault injection. Reuse the official image loader, memory
// representation, read service, pin driving and validation without editing it.
#define main cpu2026_official_main_not_used
#include "../../scripts/sim.cpp"
#undef main
#include <cstdlib>
#include <utility>

struct FaultMemory : Memory {
    uint32_t fault_address = 0;
    bool fault_used = false;
    uint64_t fault_extra_delay = 0;
    std::vector<std::pair<uint32_t, uint8_t>> expected_bytes;

    void configure() {
        const char *fault = std::getenv("CPU_TEST_FAULT_WRITE");
        if (!fault) throw std::runtime_error("CPU_TEST_FAULT_WRITE is required");
        fault_address = uint32_t(std::stoull(fault, nullptr, 0));
        if (const char *delay = std::getenv("CPU_TEST_FAULT_EXTRA_DELAY"))
            fault_extra_delay = std::stoull(delay, nullptr, 0);
        if (const char *filename = std::getenv("CPU_TEST_EXPECT_MEMORY")) {
            std::ifstream input(filename);
            if (!input) throw std::runtime_error("cannot open expected memory");
            uint32_t address, value;
            while (input >> std::hex >> address >> value) {
                if (address >= bytes.size() || value > 255)
                    throw std::runtime_error("expected memory entry out of range");
                expected_bytes.emplace_back(address, uint8_t(value));
            }
        }
    }

    void write(unsigned latency) {
        if (!fault_used && aw.front() == fault_address) {
            uint32_t address = aw.front();
            aw.pop_front();
            w.pop_front();
            b.push_back({2, 0, cycle + latency + fault_extra_delay, false});
            fault_used = true;
            std::cout << "CPU_BUS WRITE_ERROR cycle=" << cycle << " addr="
                      << std::hex << address << std::dec << std::endl;
        } else Memory::write(latency);
    }

    // Same queue ordering as the official slave; the only behavioral change is
    // dispatching a matching write to the one-shot SLVERR injector above.
    void step(const Vstudent_top &top, unsigned latency) {
        if (top.reset) {
            Memory::step(top, latency);
            fault_used = false;
            return;
        }
        ++cycle;
        if (top.rvalid && top.rready) r.pop_front();
        if (top.bvalid && top.bready) {
            if (b.front().exit) { done = true; result = b.front().result; }
            b.pop_front();
        }
        bool do_read = !ar.empty() && r.size() < DEPTH;
        bool do_write = !aw.empty() && !w.empty() && b.size() < DEPTH;
        bool write_first = false;
        if (do_read && do_write) {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5;
            write_first = random & 1;
        }
        if (do_write && write_first) write(latency);
        if (do_read) read(latency);
        if (do_write && !write_first) write(latency);
        if (top.arvalid && top.arready) ar.push_back(top.araddr);
        if (top.awvalid && top.awready) {
            if (top.awaddr == EXIT_ADDRESS) {
                if (!aw.empty() || !b.empty())
                    throw std::runtime_error("exit AW before previous write responses drained");
                for (const auto &entry : expected_bytes)
                    if (bytes[entry.first] != entry.second)
                        throw std::runtime_error("exit AW before committed RAM bytes became externally visible");
                std::cout << "CPU_BUS EXIT_RAM_VISIBLE cycle=" << cycle
                          << " bytes=" << expected_bytes.size() << '\n';
            }
            aw.push_back(top.awaddr);
        }
        if (top.wvalid && top.wready) w.push_back({top.wdata, top.wstrb});
    }
};

int main(int argc, char **argv) {
    if (argc != 5) {
        std::cerr << "usage: fault_sim IMAGE EXPECTED MAX_CYCLES LATENCY\n";
        return 2;
    }
    try {
        uint32_t expected = uint32_t(decimal(argv[2], "expected result", 0xffffffff));
        uint64_t limit = decimal(argv[3], "cycle limit", (uint64_t(1) << 63) - 1);
        unsigned latency = unsigned(decimal(argv[4], "latency", 1000000));
        if (!limit || !latency) throw std::runtime_error("cycle limit and latency must be positive");
        FaultMemory memory;
        memory.configure();
        memory.load(argv[1]);
        VerilatedContext context;
        context.commandArgs(argc, argv);
        Vstudent_top top{&context};
        auto tick = [&]() {
            top.clock = 0;
            memory.drive(top);
            top.eval();
            context.timeInc(1);
            memory.step(top, latency);
            top.clock = 1;
            top.eval();
            context.timeInc(1);
        };
        top.reset = 1;
        for (unsigned i = 0; i < 5; ++i) tick();
        top.reset = 0;
        while (!memory.done && memory.cycle < limit && !context.gotFinish()) tick();
        top.final();
        bool pass = memory.done && memory.result == expected && memory.fault_used;
        std::cout << (pass ? "PASS" : "FAIL") << " cycles=" << memory.cycle;
        if (memory.done) std::cout << " result=" << memory.result << " expected=" << expected;
        else std::cout << " (timeout or finish before exit write response)";
        std::cout << '\n';
        return pass ? 0 : 1;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
