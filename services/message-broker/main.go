// services/message-broker/main.go
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// Add a logger instance
var logger *log.Logger

func init() {
	// Initialize logger to write to a file in the logs directory
	// Ensure the logs directory exists (you might need os.MkdirAll in main() if not sure)
	logFile, err := os.OpenFile("../logs/message-broker-startup.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
	if err != nil {
		log.Fatalf("Failed to open log file: %v", err)
	}
	// Create a logger that writes to both the file and standard output (captured by start-system.sh)
	// Using a multi-writer might be complex, so we'll primarily log to the file and rely on start-system.sh
	// to capture stdout/stderr. For now, let's just log to the file.
	// A better approach would be to use a proper logging library like logrus or zap.
	logger = log.New(logFile, "MESSAGE_BROKER: ", log.LstdFlags|log.Lshortfile)
}

type MessageBroker struct {
	nc *nats.Conn
	js jetstream.JetStream
}

func NewMessageBroker(natsURL string) (*MessageBroker, error) {
	logger.Printf("Attempting to connect to NATS at %s", natsURL)
	nc, err := nats.Connect(natsURL,
		// Add connection callbacks for better logging
		nats.DisconnectErrHandler(func(nc *nats.Conn, err error) {
			logger.Printf("NATS Disconnected due to: %v", err)
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			logger.Printf("NATS Reconnected to %v", nc.ConnectedUrl())
		}),
		nats.ClosedHandler(func(nc *nats.Conn) {
			logger.Printf("NATS Connection closed. Reason: %v", nc.LastError())
		}),
	)
	if err != nil {
		logger.Printf("ERROR: Failed to connect to NATS: %v", err)
		return nil, err
	}
	logger.Printf("SUCCESS: Connected to NATS server at %s", nc.ConnectedUrl())

	js, err := jetstream.New(nc)
	if err != nil {
		logger.Printf("ERROR: Failed to initialize JetStream context: %v", err)
		nc.Close()
		return nil, err
	}
	logger.Println("SUCCESS: JetStream context initialized")

	return &MessageBroker{nc: nc, js: js}, nil
}

func (mb *MessageBroker) setupStreams() error {
    streams := []jetstream.StreamConfig{
        {
            Name:        "TASKS",
            Description: "Task orchestration stream",
            Subjects:    []string{"tasks.*"},
            MaxAge:      24 * time.Hour,
        },
        {
            Name:        "AGENTS",
            Description: "Agent management stream",
            Subjects:    []string{"agents.*"},
            MaxAge:      1 * time.Hour,
        },
        {
            Name:        "VECTORS",
            Description: "Vector operations stream",
            Subjects:    []string{"vectors.*"},
            MaxAge:      1 * time.Hour,
        },
    }

    for _, streamConfig := range streams {
        _, err := mb.js.CreateStream(context.Background(), streamConfig)
        if err != nil {
            log.Printf("Stream %s might already exist: %v", streamConfig.Name, err)
        }
    }

    return nil
}

func (mb *MessageBroker) PublishMessage(subject string, data []byte) error {
    _, err := mb.js.Publish(context.Background(), subject, data)
    return err
}

func (mb *MessageBroker) SubscribeToSubject(subject string) error {
    // Find the appropriate stream
    streamName := "TASKS"
    if subject == "agents.*" {
        streamName = "AGENTS"
    } else if subject == "vectors.*" {
        streamName = "VECTORS"
    }

    consumer, err := mb.js.CreateConsumer(context.Background(), streamName, jetstream.ConsumerConfig{
        FilterSubject: subject,
        AckPolicy:     jetstream.AckExplicitPolicy,
    })
    if err != nil {
        return err
    }

    _, err = consumer.Consume(func(msg jetstream.Msg) {
        log.Printf("Received message on %s: %s", subject, string(msg.Data()))
        msg.Ack()
    })

    return err
}

func main() {
	// Log startup
	logger.Println("=== Message Broker Service Starting ===")

	broker, err := NewMessageBroker(nats.DefaultURL) // Connects to nats://localhost:4222
	if err != nil {
		logger.Fatalf("Failed to create message broker: %v", err)
		// log.Fatal will also print to stderr, which start-system.sh captures
		log.Fatalf("Failed to create message broker: %v", err)
	}
	defer func() {
		logger.Println("Closing NATS connection...")
		broker.nc.Close()
	}()

	logger.Println("Setting up JetStream streams...")
	// Setup JetStream streams
	err = broker.setupStreams()
	if err != nil {
		logger.Printf("Warning: Error setting up streams: %v", err)
		// Not necessarily fatal, streams might exist
	}

	logger.Println("Subscribing to task messages...")
	// Subscribe to task messages
	err = broker.SubscribeToSubject("tasks.*")
	if err != nil {
		logger.Printf("Failed to subscribe to tasks: %v", err)
		log.Printf("Failed to subscribe to tasks: %v", err) // Also to stderr
		// Depending on requirements, this might be fatal
		// log.Fatalf("Failed to subscribe to tasks: %v", err)
	}

	logger.Println("Message broker is now running and listening for messages...")
	log.Println("Message broker started successfully and is listening...") // To stdout for start-system.sh

	// Graceful shutdown
	c := make(chan os.Signal, 1)
	signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
	<-c
	logger.Println("Message broker shutting down...")
	log.Println("Message broker shutting down...") // To stdout for start-system.sh
}