
import SwiftUI

enum SimulatorType {
    case none
    case water
    case gas
    case cloth
}

struct ContentView: View {
    @State private var selectedSimulator: SimulatorType = .none
    
    var body: some View {
        ZStack {
            // Background - Deep midnight gradient
            LinearGradient(colors: [Color(white: 0.05), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            
            if selectedSimulator == .none {
                VStack(spacing: 40) {
                    VStack(spacing: 12) {
                        Text("PHYSICS LAB")
                            .font(.system(size: 14, weight: .black))
                            .kerning(4)
                            .foregroundStyle(.white.opacity(0.4))
                        
                        Text("Simulations")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 20)
                    
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                            MenuButton(title: "WATER", icon: "drop.fill", color: .blue, description: "Fluid Dynamics") {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { selectedSimulator = .water }
                            }
                            
                            MenuButton(title: "GAS", icon: "smoke.fill", color: .orange, description: "Eulerian Flow") {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { selectedSimulator = .gas }
                            }
                            
                            MenuButton(title: "CLOTH", icon: "tshirt.fill", color: .purple, description: "XPBD Physics") {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { selectedSimulator = .cloth }
                            }
                        }
                        .padding(.horizontal, 25)
                        .padding(.bottom, 40)
                    }
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                Group {
                    if selectedSimulator == .water {
                        WaterView(onExit: { withAnimation { selectedSimulator = .none } })
                    } else if selectedSimulator == .gas {
                        GasView(onExit: { withAnimation { selectedSimulator = .none } })
                    } else if selectedSimulator == .cloth {
                        ClothView(onExit: { withAnimation { selectedSimulator = .none } })
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }
        }
    }
}

struct MenuButton: View {
    let title: String
    let icon: String
    let color: Color
    let description: String
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 20) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(color)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .black))
                        .kerning(1)
                        .foregroundStyle(.white)
                    
                    Text(description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(.ultraThinMaterial)
            .cornerRadius(25)
            .overlay(
                RoundedRectangle(cornerRadius: 30)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

#Preview {
    ContentView()
}
