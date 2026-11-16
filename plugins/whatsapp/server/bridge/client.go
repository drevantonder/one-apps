package main

import (
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store"
)

// newClient is the link's client to WhatsApp: whatsmeow's. The test puts a fake in this file's place.
func newClient(device *store.Device) whatsApp {
	c := whatsmeow.NewClient(device, logger{"whatsmeow"})
	// Contacts' names arrive as app state: each is told as an event, even in the first full sync.
	c.EmitAppStateEventsOnFullSync = true
	return c
}
