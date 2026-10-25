package presence

import (
	"context"
	"testing"
)

func TestLowerSequenceAndForeignConnectionCannotRewriteState(t *testing.T) {
	f := setup(t)
	writer := f.connect(t)
	f.submit(t, writer, 1, "第一份")
	f.submit(t, writer, 2, "第二份")
	if _, ok := f.submit(t, writer, 1, "第一份"); ok {
		t.Fatal("older sequence accepted")
	}
	if writer.Termination().Code != "out_of_order" {
		t.Fatal("older sequence was not rejected as out of order")
	}
	current := f.connect(t)
	f.submit(t, current, 1, "当前内容")
	candidate := f.connect(t)
	foreign, fingerprint := snapshot(t, current, 1, "伪造内容")
	if _, ok := f.manager.Submit(candidate, foreign, fingerprint); ok {
		t.Fatal("foreign connection ID accepted")
	}
	if candidate.Termination().Code != "invalid_message" {
		t.Fatal("wrong identity error")
	}
	if got := f.read(t).Devices[0]; !got.Online || got.Sources.Window.Title != "当前内容" {
		t.Fatal("foreign candidate altered current writer")
	}
}

func TestDevicesRemainIndependentWithinOneReceiver(t *testing.T) {
	f := setup(t)
	first := f.connect(t)
	f.submit(t, first, 1, "第一设备窗口")
	device, token, err := f.manager.CreateDevice(context.Background(), f.owner, "第二虚构设备")
	if err != nil {
		t.Fatal(err)
	}
	second, err := f.manager.Register(context.Background(), token)
	if err != nil {
		t.Fatal(err)
	}
	f.manager.Activate(second)
	f.submit(t, second, 1, "第二设备窗口")
	projection := f.read(t)
	if len(projection.Devices) != 2 {
		t.Fatal("devices were merged or selected")
	}
	for _, item := range projection.Devices {
		if !item.Online || item.Sources.Window == nil {
			t.Fatal("device presence missing")
		}
		if item.DeviceID == device.ID && item.Sources.Window.Title != "第二设备窗口" {
			t.Fatal("second device got another source")
		}
		if item.DeviceID == f.device.ID && item.Sources.Window.Title != "第一设备窗口" {
			t.Fatal("first device got another source")
		}
	}
	f.manager.Disconnect(first)
	for _, item := range f.read(t).Devices {
		if item.DeviceID == device.ID && !item.Online {
			t.Fatal("one device disconnect cleared another")
		}
	}
}
